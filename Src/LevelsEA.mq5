#property strict
#property version   "1.00"
#property description "POI touch and break volume EA (pure MQL5)"

#include <Trade/Trade.mqh>

input group "1) POI Detection (Core Strategy)"
input int      InpTouchCount                 = 3;        // How many touches are needed before a POI line is confirmed (typical: 3-5)
input int      InpTouchTolerancePoints       = 20;       // Price tolerance for counting a touch, in points (higher = easier to count touches)
input int      InpMaxLevelCandidates         = 300;      // Internal memory for possible levels (leave default unless EA misses levels)
input bool     InpUseHighAndLowAsTouches     = true;     // true = count candle High/Low as touches (recommended for beginners)
input bool     InpUseCloseAsTouchSource      = false;    // true = also count candle Close as touches (can increase signals/noise)
input bool     InpResetAfterBreak            = true;     // true = after a break, old POI is cleared and a new one is searched

input group "2) Chart Display (Visual Only)"
input color    InpPOILineColor               = clrOrange; // POI horizontal line color
input int      InpPOILineWidth               = 2;         // POI line thickness
input ENUM_LINE_STYLE InpPOILineStyle        = STYLE_SOLID; // POI line style
input color    InpBreakMarkerColor           = clrBlue;   // Break candle highlight color
input bool     InpShowVolumeCheckText        = true;      // Show text: break volume highest or not
input int      InpVolumeTextFontSize         = 8;         // Text size for break label

input group "3) Trading & Risk (levels) - Beginner Friendly"
input bool     InpEnableTrading              = false;    // Master switch: OFF = no trades, ON = EA can trade
input bool     InpUseRiskBasedSizing         = true;     // ON = lot size uses Risk %; OFF = fixed lot size
input double   InpRiskPercent                = 1.0;      // Risk per trade (%) when risk-based sizing is ON
input double   InpFixedLotIfRiskOff          = 0.10;     // Fixed lot size (used when risk sizing is OFF/invalid)
input bool     InpUseStopLoss                = true;     // ON = place Stop Loss on entry
input int      InpStopLossPoints             = 300;      // Stop Loss distance in points
input bool     InpUseTakeProfit              = true;     // ON = place Take Profit on entry
input int      InpTakeProfitPoints           = 600;      // Take Profit distance in points
input double   InpMinLot                     = 0.01;     // Minimum lot size allowed
input double   InpMaxLot                     = 100.0;    // Maximum lot size allowed
input int      InpSlippagePoints             = 20;       // Max allowed slippage (points)
input bool     InpAllowBuy                   = true;     // Allow BUY entries
input bool     InpAllowSell                  = true;     // Allow SELL entries
input ulong    InpMagicNumber                = 550001;   // Unique strategy ID (magic number)
input bool     InpUseSpreadFilter            = true;     // ON = block entries when spread is too high
input int      InpMaxSpreadPoints            = 30;       // Max spread allowed (points)
input bool     InpUseHardProfitLock          = true;     // ON = stop trading after daily profit target is hit
input double   InpHardProfitTargetMoney      = 100.0;    // Daily profit target in account currency
input bool     InpClosePositionsOnHardLock   = true;     // ON = close managed positions when profit lock is hit
input bool     InpRiskScopeMagicOnly         = true;     // Manage only this EA's magic number
input bool     InpRiskScopeSymbolOnly        = true;     // Manage only this chart symbol
input bool     InpEnableTrailing             = true;     // ON = use trailing stop
input int      InpTrailingStartPoints        = 200;      // Start trailing after this profit (points)
input int      InpTrailingDistancePoints     = 150;      // Trailing SL gap from current price (points)
input int      InpTrailingStepPoints         = 20;       // Minimum SL move before updating trailing (points)

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

   if(!InpUseHardProfitLock || InpHardProfitTargetMoney <= 0.0)
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

   if(InpUseSpreadFilter && InpMaxSpreadPoints > 0)
   {
      const double spread_points = (ask - bid) / _Point;
      if(spread_points > InpMaxSpreadPoints)
         return false;
   }

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
   if(!InpUseRiskBasedSizing)
      return InpFixedLotIfRiskOff;
   if(!InpUseStopLoss)
      return InpFixedLotIfRiskOff;

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
      const double sl = InpUseStopLoss ? NormalizeDouble(entry - InpStopLossPoints * _Point, _Digits) : 0.0;
      const double tp = InpUseTakeProfit ? NormalizeDouble(entry + InpTakeProfitPoints * _Point, _Digits) : 0.0;
      const double lots = CalculateLotsByRisk(entry, sl);
      g_trade.Buy(lots, _Symbol, 0.0, sl, tp, "levels buy break");
   }
   else if(direction < 0)
   {
      const double entry = bid;
      const double sl = InpUseStopLoss ? NormalizeDouble(entry + InpStopLossPoints * _Point, _Digits) : 0.0;
      const double tp = InpUseTakeProfit ? NormalizeDouble(entry - InpTakeProfitPoints * _Point, _Digits) : 0.0;
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
   if(InpUseStopLoss && InpStopLossPoints < 1)
      return INIT_PARAMETERS_INCORRECT;
   if(InpUseTakeProfit && InpTakeProfitPoints < 1)
      return INIT_PARAMETERS_INCORRECT;
   if(InpUseRiskBasedSizing && InpRiskPercent < 0.0)
      return INIT_PARAMETERS_INCORRECT;
   if(InpFixedLotIfRiskOff <= 0.0)
      return INIT_PARAMETERS_INCORRECT;
   if(InpUseHardProfitLock && InpHardProfitTargetMoney < 0.0)
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
