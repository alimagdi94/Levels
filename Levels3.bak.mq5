#property strict
#property version   "1.00"
#property description "POI touch and break volume EA (pure MQL5)"

#include <Trade/Trade.mqh>

input group "General"
input int      InpTouchCount                 = 3;        // Required touches to lock POI
input int      InpTouchTolerancePoints       = 20;       // Touch tolerance (points)
input int      InpMaxLevelCandidates         = 300;      // Internal candidate capacity
input bool     InpUseHighAndLowAsTouches     = true;     // Use both high and low as touch sources
input bool     InpUseCloseAsTouchSource      = false;    // Also use close as touch source
input bool     InpResetAfterBreak            = true;     // Build a new POI after break

input group "Visuals"
input color    InpPOILineColor               = clrOrange;
input int      InpPOILineWidth               = 2;
input ENUM_LINE_STYLE InpPOILineStyle        = STYLE_SOLID;
input color    InpBreakMarkerColor           = clrBlue;
input bool     InpShowVolumeCheckText        = true;
input int      InpVolumeTextFontSize         = 8;

input group "levels (Risk Management)"
input bool     InpEnableTrading              = false;    // If true, place market order on valid break
input double   InpRiskPercent                = 1.0;      // Risk per trade (% of balance)
input double   InpFixedLotIfRiskOff          = 0.10;     // Used when risk is 0 or SL invalid
input int      InpStopLossPoints             = 300;      // Stop loss distance in points
input int      InpTakeProfitPoints           = 600;      // Take profit distance in points
input double   InpMinLot                     = 0.01;     // Lot clamp min
input double   InpMaxLot                     = 100.0;    // Lot clamp max
input int      InpSlippagePoints             = 20;       // Max slippage (points)
input bool     InpAllowBuy                   = true;
input bool     InpAllowSell                  = true;
input ulong    InpMagicNumber                = 550001;
input int      InpMaxSpreadPoints            = 30;       // Hard spread filter in points
input double   InpHardProfitTargetMoney      = 100.0;    // Hard DAILY profit target in account currency (0 = off)
input bool     InpClosePositionsOnHardLock   = true;     // Close strategy positions when hard lock triggers
input bool     InpRiskScopeMagicOnly         = true;     // Apply management only to this EA magic
input bool     InpRiskScopeSymbolOnly        = true;     // Apply management only to chart symbol
input bool     InpEnableTrailing             = true;     // Enable trailing stop management
input int      InpTrailingStartPoints        = 200;      // Start trailing after profit >= this many points
input int      InpTrailingDistancePoints     = 150;      // SL distance from current price in points
input int      InpTrailingStepPoints         = 20;       // Minimum SL improvement step in points

struct SLevelCandidate
{
   double   price;
   int      touches;
   datetime last_touch_time;
};

CTrade g_trade;
SLevelCandidate g_candidates[];
datetime g_last_bar_time = 0;

bool   g_poi_active               = false;
double g_poi_price                = 0.0;
double g_max_touch_volume         = 0.0;
string g_poi_line_name            = "";
int    g_break_count              = 0;
bool   g_risk_lock_active         = false;
datetime g_risk_day_start         = 0;
double g_risk_day_start_balance   = 0.0;

string BuildPrefix()
{
   return StringFormat("LEVELS_%s_%I64d_", _Symbol, (long)Period());
}

string POILineName()
{
   return BuildPrefix() + "POI_LINE";
}

string BreakRectName(const datetime t)
{
   return BuildPrefix() + "BREAK_RECT_" + IntegerToString((int)t);
}

string BreakTextName(const datetime t)
{
   return BuildPrefix() + "BREAK_TEXT_" + IntegerToString((int)t);
}

datetime DayStartTime(const datetime t)
{
   MqlDateTime dt;
   TimeToStruct(t, dt);
   dt.hour = 0;
   dt.min = 0;
   dt.sec = 0;
   return StructToTime(dt);
}

void CloseManagedPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;

      if(InpRiskScopeMagicOnly)
      {
         const long pos_magic = PositionGetInteger(POSITION_MAGIC);
         if((ulong)pos_magic != InpMagicNumber)
            continue;
      }

      if(InpRiskScopeSymbolOnly)
      {
         const string pos_symbol = PositionGetString(POSITION_SYMBOL);
         if(pos_symbol != _Symbol)
            continue;
      }

      g_trade.PositionClose(ticket);
   }
}

void RefreshHardProfitLock()
{
   const datetime now = TimeCurrent();
   const datetime day_start = DayStartTime(now);

   if(g_risk_day_start != day_start)
   {
      g_risk_day_start = day_start;
      g_risk_day_start_balance = AccountInfoDouble(ACCOUNT_BALANCE);
      g_risk_lock_active = false;
   }

   if(InpHardProfitTargetMoney <= 0.0)
      return;

   const double baseline = (g_risk_day_start_balance > 0.0) ? g_risk_day_start_balance : AccountInfoDouble(ACCOUNT_BALANCE);
   const double equity_now = AccountInfoDouble(ACCOUNT_EQUITY);
   const double day_profit = equity_now - baseline;
   if(day_profit >= InpHardProfitTargetMoney)
      g_risk_lock_active = true;
}

bool IsTradingAllowedByRisk()
{
   RefreshHardProfitLock();

   if(g_risk_lock_active)
   {
      if(InpClosePositionsOnHardLock)
         CloseManagedPositions();
      return false;
   }

   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0)
      return false;

   const double spread_points = (ask - bid) / _Point;
   if(InpMaxSpreadPoints > 0 && spread_points > InpMaxSpreadPoints)
      return false;

   return true;
}

void ManageTrailingStops()
{
   if(!InpEnableTrailing)
      return;
   if(InpTrailingStartPoints <= 0 || InpTrailingDistancePoints <= 0 || InpTrailingStepPoints <= 0)
      return;

   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(bid <= 0.0 || ask <= 0.0)
      return;

   g_trade.SetExpertMagicNumber(InpMagicNumber);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;

      if(InpRiskScopeMagicOnly)
      {
         const long pos_magic = PositionGetInteger(POSITION_MAGIC);
         if((ulong)pos_magic != InpMagicNumber)
            continue;
      }
      if(InpRiskScopeSymbolOnly)
      {
         const string pos_symbol = PositionGetString(POSITION_SYMBOL);
         if(pos_symbol != _Symbol)
            continue;
      }

      const ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      const double open = PositionGetDouble(POSITION_PRICE_OPEN);
      const double current_sl = PositionGetDouble(POSITION_SL);
      const double current_tp = PositionGetDouble(POSITION_TP);

      if(type == POSITION_TYPE_BUY)
      {
         const double profit_points = (bid - open) / _Point;
         if(profit_points < InpTrailingStartPoints)
            continue;

         const double proposed_sl = NormalizeDouble(bid - InpTrailingDistancePoints * _Point, _Digits);
         const bool has_no_sl = (current_sl <= 0.0);
         const bool enough_step = ((proposed_sl - current_sl) / _Point) >= InpTrailingStepPoints;
         if((has_no_sl || enough_step) && proposed_sl < bid)
            g_trade.PositionModify(ticket, proposed_sl, current_tp);
      }
      else if(type == POSITION_TYPE_SELL)
      {
         const double profit_points = (open - ask) / _Point;
         if(profit_points < InpTrailingStartPoints)
            continue;

         const double proposed_sl = NormalizeDouble(ask + InpTrailingDistancePoints * _Point, _Digits);
         const bool has_no_sl = (current_sl <= 0.0);
         const bool enough_step = ((current_sl - proposed_sl) / _Point) >= InpTrailingStepPoints;
         if((has_no_sl || enough_step) && proposed_sl > ask)
            g_trade.PositionModify(ticket, proposed_sl, current_tp);
      }
   }
}

double NormalizePriceToStep(const double price)
{
   const double step = InpTouchTolerancePoints * _Point;
   if(step <= 0.0)
      return NormalizeDouble(price, _Digits);

   const double bucket = MathRound(price / step) * step;
   return NormalizeDouble(bucket, _Digits);
}

bool CandleTouchesLevel(const double high, const double low, const double level)
{
   const double tol = InpTouchTolerancePoints * _Point;
   return (high >= level - tol && low <= level + tol);
}

bool CandleBreaksLevel(const double open, const double close, const double level, int &direction)
{
   direction = 0;
   if(open < level && close > level)
   {
      direction = 1;
      return true;
   }
   if(open > level && close < level)
   {
      direction = -1;
      return true;
   }
   return false;
}

void ResetPOI()
{
   g_poi_active = false;
   g_poi_price = 0.0;
   g_max_touch_volume = 0.0;
   g_break_count = 0;
   ObjectDelete(0, POILineName());
}

void EnsurePOILine()
{
   const string name = POILineName();
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_HLINE, 0, 0, g_poi_price);

   ObjectSetDouble(0, name, OBJPROP_PRICE, g_poi_price);
   ObjectSetInteger(0, name, OBJPROP_COLOR, InpPOILineColor);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, InpPOILineWidth);
   ObjectSetInteger(0, name, OBJPROP_STYLE, InpPOILineStyle);
}

void MarkBreakCandle(const datetime t, const double high, const double low, const bool is_highest)
{
   const string rect_name = BreakRectName(t);
   ObjectCreate(0, rect_name, OBJ_RECTANGLE, 0, t, high, t + PeriodSeconds(), low);
   ObjectSetInteger(0, rect_name, OBJPROP_COLOR, InpBreakMarkerColor);
   ObjectSetInteger(0, rect_name, OBJPROP_STYLE, STYLE_SOLID);
   ObjectSetInteger(0, rect_name, OBJPROP_FILL, true);
   ObjectSetInteger(0, rect_name, OBJPROP_BACK, false);

   if(!InpShowVolumeCheckText)
      return;

   const string txt_name = BreakTextName(t);
   const string txt = is_highest ? "BreakVol=Highest" : "BreakVol<Highest";
   ObjectCreate(0, txt_name, OBJ_TEXT, 0, t, high + (10 * _Point));
   ObjectSetString(0, txt_name, OBJPROP_TEXT, txt);
   ObjectSetInteger(0, txt_name, OBJPROP_COLOR, InpBreakMarkerColor);
   ObjectSetInteger(0, txt_name, OBJPROP_FONTSIZE, InpVolumeTextFontSize);
}

double CalculateLotsByRisk(const double entry_price, const double stop_price)
{
   const double risk_pct = InpRiskPercent;
   if(risk_pct <= 0.0)
      return InpFixedLotIfRiskOff;

   const double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   const double risk_money = balance * (risk_pct / 100.0);
   if(risk_money <= 0.0)
      return InpFixedLotIfRiskOff;

   const double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   const double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tick_size <= 0.0 || tick_value <= 0.0)
      return InpFixedLotIfRiskOff;

   const double price_distance = MathAbs(entry_price - stop_price);
   if(price_distance <= 0.0)
      return InpFixedLotIfRiskOff;

   const double money_per_lot = (price_distance / tick_size) * tick_value;
   if(money_per_lot <= 0.0)
      return InpFixedLotIfRiskOff;

   double lots = risk_money / money_per_lot;

   const double vol_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   const double vol_min = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   const double vol_max = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   const double hard_min = MathMax(InpMinLot, vol_min);
   const double hard_max = MathMin(InpMaxLot, vol_max);
   if(vol_step > 0.0)
      lots = MathFloor(lots / vol_step) * vol_step;

   lots = MathMax(hard_min, lots);
   lots = MathMin(hard_max, lots);
   return lots;
}

void TryTradeOnBreak(const int direction)
{
   if(!InpEnableTrading)
      return;
   if(!IsTradingAllowedByRisk())
      return;

   if(PositionSelect(_Symbol))
      return;

   if(direction > 0 && !InpAllowBuy)
      return;
   if(direction < 0 && !InpAllowSell)
      return;

   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(InpSlippagePoints);

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0)
      return;

   if(direction > 0)
   {
      const double entry = ask;
      const double sl = NormalizeDouble(entry - InpStopLossPoints * _Point, _Digits);
      const double tp = NormalizeDouble(entry + InpTakeProfitPoints * _Point, _Digits);
      const double lots = CalculateLotsByRisk(entry, sl);
      g_trade.Buy(lots, _Symbol, 0.0, sl, tp, "levels buy break");
   }
   else if(direction < 0)
   {
      const double entry = bid;
      const double sl = NormalizeDouble(entry + InpStopLossPoints * _Point, _Digits);
      const double tp = NormalizeDouble(entry - InpTakeProfitPoints * _Point, _Digits);
      const double lots = CalculateLotsByRisk(entry, sl);
      g_trade.Sell(lots, _Symbol, 0.0, sl, tp, "levels sell break");
   }
}

int FindCandidateIndex(const double level)
{
   const int n = ArraySize(g_candidates);
   for(int i = 0; i < n; i++)
   {
      if(MathAbs(g_candidates[i].price - level) <= (InpTouchTolerancePoints * _Point))
         return i;
   }
   return -1;
}

void AddTouchCandidate(const double raw_price, const datetime t)
{
   const double level = NormalizePriceToStep(raw_price);
   int idx = FindCandidateIndex(level);
   if(idx < 0)
   {
      const int n = ArraySize(g_candidates);
      if(n >= InpMaxLevelCandidates)
         return;
      ArrayResize(g_candidates, n + 1);
      g_candidates[n].price = level;
      g_candidates[n].touches = 1;
      g_candidates[n].last_touch_time = t;
      return;
   }

   if(g_candidates[idx].last_touch_time == t)
      return;

   g_candidates[idx].touches++;
   g_candidates[idx].last_touch_time = t;

   if(!g_poi_active && g_candidates[idx].touches >= InpTouchCount)
   {
      g_poi_active = true;
      g_poi_price = g_candidates[idx].price;
      g_max_touch_volume = 0.0;
      EnsurePOILine();
   }
}

void ProcessClosedBar()
{
   MqlRates bar[1];
   if(CopyRates(_Symbol, _Period, 1, 1, bar) != 1)
      return;

   const datetime t = bar[0].time;
   if(t == g_last_bar_time)
      return;
   g_last_bar_time = t;

   const double open = bar[0].open;
   const double high = bar[0].high;
   const double low  = bar[0].low;
   const double close = bar[0].close;
   const double volume = (double)bar[0].tick_volume;

   if(!g_poi_active)
   {
      if(InpUseHighAndLowAsTouches)
      {
         AddTouchCandidate(high, t);
         AddTouchCandidate(low, t);
      }
      if(InpUseCloseAsTouchSource)
         AddTouchCandidate(close, t);
      return;
   }

   EnsurePOILine();

   const bool touched_poi = CandleTouchesLevel(high, low, g_poi_price);
   if(touched_poi)
      g_max_touch_volume = MathMax(g_max_touch_volume, volume);

   int direction = 0;
   const bool broke = CandleBreaksLevel(open, close, g_poi_price, direction);
   if(!broke)
      return;

   const bool highest = (volume >= g_max_touch_volume);
   MarkBreakCandle(t, high, low, highest);
   TryTradeOnBreak(direction);

   g_break_count++;
   if(InpResetAfterBreak)
   {
      ArrayResize(g_candidates, 0);
      ResetPOI();
   }
}

int OnInit()
{
   if(InpTouchCount < 2)
      return INIT_PARAMETERS_INCORRECT;
   if(InpTouchTolerancePoints < 1)
      return INIT_PARAMETERS_INCORRECT;
   if(InpStopLossPoints < 1 || InpTakeProfitPoints < 1)
      return INIT_PARAMETERS_INCORRECT;
   if(InpRiskPercent < 0.0 || InpFixedLotIfRiskOff <= 0.0)
      return INIT_PARAMETERS_INCORRECT;
   if(InpHardProfitTargetMoney < 0.0)
      return INIT_PARAMETERS_INCORRECT;

   ArrayResize(g_candidates, 0);
   g_last_bar_time = 0;
   g_poi_line_name = POILineName();
   g_risk_day_start = 0;
   g_risk_day_start_balance = 0.0;
   g_risk_lock_active = false;
   ResetPOI();
   return INIT_SUCCEEDED;
}

void OnTick()
{
   RefreshHardProfitLock();
   if(g_risk_lock_active && InpClosePositionsOnHardLock)
      CloseManagedPositions();
   ManageTrailingStops();
   ProcessClosedBar();
}

void OnDeinit(const int reason)
{
   ObjectDelete(0, POILineName());
}
