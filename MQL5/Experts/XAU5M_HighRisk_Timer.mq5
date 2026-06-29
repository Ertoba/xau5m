//+------------------------------------------------------------------+
//|                                           XAU5M_HighRisk_Timer.mq5 |
//|  Aggressive XAUUSD M5 timer EA for demo/stress testing only.      |
//|  Opens one 0.10 lot position per new M5 candle, max 5 positions.  |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"
#property description "High-risk XAUUSD M5 timer scalper for demo testing"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

CTrade        Trade;
CPositionInfo Position;

//-------------------- Demo and symbol guard --------------------
input bool   RequireDemoAccount      = true;
input string AllowedSymbol           = "XAUUSD";
input bool   AllowBrokerSuffix       = true;
input ulong  MagicNumber             = 2026062905;
input string TradeComment            = "XAU5M_TIMER";

//-------------------- Position schedule --------------------
input ENUM_TIMEFRAMES EntryTimeframe  = PERIOD_M5;
input int    TimerSeconds            = 10;
input int    OpenEveryMinutes        = 5;
input int    MaxOpenPositions        = 5;
input double Lots                    = 0.10;
input int    SlippagePoints          = 30;

//-------------------- Aggressive M5 signal score --------------------
input int    EMAFastPeriod           = 20;
input int    EMASlowPeriod           = 50;
input int    RSIPeriod               = 14;
input int    MACDFast                = 12;
input int    MACDSlow                = 26;
input int    MACDSignal              = 9;
input int    ATRPeriod               = 14;
input double RSIUpperBias            = 55.0;
input double RSILowerBias            = 45.0;

//-------------------- Risk controls --------------------
input bool   UseSpreadFilter         = true;
input double MaxSpreadPoints         = 120.0;
input double ATRStopMultiplier       = 1.00;
input double ATRTakeProfitMultiplier = 1.20;
input int    MinStopPoints           = 250;
input int    MaxStopPoints           = 1800;
input bool   CloseOppositePositions  = false;
input int    MaxHoldMinutes          = 25;

//-------------------- Position management --------------------
input bool   UseBreakEven            = true;
input double BreakEvenAtR            = 0.80;
input int    BreakEvenBufferPoints   = 30;
input bool   UseTrailingStop         = true;
input double TrailStartR             = 1.00;
input double TrailATRMultiplier      = 0.80;

int      HandleFastMA = INVALID_HANDLE;
int      HandleSlowMA = INVALID_HANDLE;
int      HandleRSI = INVALID_HANDLE;
int      HandleMACD = INVALID_HANDLE;
int      HandleATR = INVALID_HANDLE;
datetime LastOpenBarTime = 0;
datetime LastOpenAttemptTime = 0;

//+------------------------------------------------------------------+
bool IsAllowedSymbol()
{
   if(_Symbol == AllowedSymbol)
      return true;

   if(AllowBrokerSuffix && StringSubstr(_Symbol, 0, StringLen(AllowedSymbol)) == AllowedSymbol)
      return true;

   return false;
}

//+------------------------------------------------------------------+
double NormalizePrice(double price)
{
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   return NormalizeDouble(price, digits);
}

//+------------------------------------------------------------------+
int VolumeDigits(double step)
{
   int digits = 0;
   while(step < 1.0 && digits < 8)
   {
      step *= 10.0;
      digits++;
   }
   return digits;
}

//+------------------------------------------------------------------+
double NormalizeVolume(double volume)
{
   double minVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(step <= 0.0)
      step = 0.01;

   volume = MathMax(minVol, MathMin(maxVol, volume));
   double steps = MathFloor((volume - minVol) / step);
   double normalized = minVol + steps * step;
   return NormalizeDouble(normalized, VolumeDigits(step));
}

//+------------------------------------------------------------------+
double BufferValue(int handle, int bufferIndex, int shift)
{
   double data[];
   ArraySetAsSeries(data, true);

   if(handle == INVALID_HANDLE)
      return EMPTY_VALUE;

   if(CopyBuffer(handle, bufferIndex, shift, 1, data) <= 0)
      return EMPTY_VALUE;

   return data[0];
}

//+------------------------------------------------------------------+
double SpreadPoints()
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return DBL_MAX;

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point <= 0.0)
      point = _Point;

   return (tick.ask - tick.bid) / point;
}

//+------------------------------------------------------------------+
bool TradingEnvironmentOK()
{
   if(!IsAllowedSymbol())
      return false;

   if(RequireDemoAccount && AccountInfoInteger(ACCOUNT_TRADE_MODE) != ACCOUNT_TRADE_MODE_DEMO)
   {
      Print("EA stopped: RequireDemoAccount=true and this is not a demo account.");
      return false;
   }

   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED))
      return false;

   if(UseSpreadFilter && SpreadPoints() > MaxSpreadPoints)
      return false;

   return true;
}

//+------------------------------------------------------------------+
int CountOpenPositions()
{
   int count = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!Position.SelectByIndex(i))
         continue;

      if(Position.Symbol() == _Symbol && (ulong)Position.Magic() == MagicNumber)
         count++;
   }

   return count;
}

//+------------------------------------------------------------------+
bool GetRates(MqlRates &rates[])
{
   ArraySetAsSeries(rates, true);
   return CopyRates(_Symbol, EntryTimeframe, 0, 5, rates) >= 5;
}

//+------------------------------------------------------------------+
int DirectionScore()
{
   MqlRates rates[];
   if(!GetRates(rates))
      return 1;

   double fast1 = BufferValue(HandleFastMA, 0, 1);
   double fast2 = BufferValue(HandleFastMA, 0, 2);
   double slow1 = BufferValue(HandleSlowMA, 0, 1);
   double rsi1 = BufferValue(HandleRSI, 0, 1);
   double macdMain1 = BufferValue(HandleMACD, 0, 1);
   double macdSignal1 = BufferValue(HandleMACD, 1, 1);
   double macdMain2 = BufferValue(HandleMACD, 0, 2);
   double macdSignal2 = BufferValue(HandleMACD, 1, 2);

   int score = 0;

   if(fast1 != EMPTY_VALUE && slow1 != EMPTY_VALUE)
   {
      if(fast1 > slow1)
         score += 2;
      if(fast1 < slow1)
         score -= 2;

      if(fast2 != EMPTY_VALUE)
      {
         if(fast1 > fast2)
            score++;
         if(fast1 < fast2)
            score--;
      }

      if(rates[1].close > fast1)
         score++;
      if(rates[1].close < fast1)
         score--;
   }

   if(rsi1 != EMPTY_VALUE)
   {
      if(rsi1 >= RSIUpperBias)
         score++;
      if(rsi1 <= RSILowerBias)
         score--;
   }

   if(macdMain1 != EMPTY_VALUE && macdSignal1 != EMPTY_VALUE)
   {
      double hist1 = macdMain1 - macdSignal1;
      double hist2 = 0.0;
      if(macdMain2 != EMPTY_VALUE && macdSignal2 != EMPTY_VALUE)
         hist2 = macdMain2 - macdSignal2;

      if(hist1 > 0.0)
         score++;
      if(hist1 < 0.0)
         score--;

      if(hist1 > hist2)
         score++;
      if(hist1 < hist2)
         score--;
   }

   double body = rates[1].close - rates[1].open;
   double range = rates[1].high - rates[1].low;
   if(range > 0.0 && MathAbs(body) >= 0.45 * range)
   {
      if(body > 0.0)
         score++;
      if(body < 0.0)
         score--;
   }

   if(rates[1].close > rates[2].high)
      score++;
   if(rates[1].close < rates[2].low)
      score--;

   if(score == 0)
      score = (rates[1].close >= rates[1].open ? 1 : -1);

   return score;
}

//+------------------------------------------------------------------+
void CloseOpposite(int direction)
{
   if(!CloseOppositePositions)
      return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!Position.SelectByIndex(i))
         continue;

      if(Position.Symbol() != _Symbol || (ulong)Position.Magic() != MagicNumber)
         continue;

      long type = Position.Type();
      if((direction > 0 && type == POSITION_TYPE_SELL) ||
         (direction < 0 && type == POSITION_TYPE_BUY))
      {
         Trade.PositionClose(Position.Ticket());
      }
   }
}

//+------------------------------------------------------------------+
bool StopsAreValid(double entry, double sl, double tp)
{
   double minDistance = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if(minDistance <= 0.0)
      minDistance = 10.0 * _Point;

   return (MathAbs(entry - sl) >= minDistance && MathAbs(tp - entry) >= minDistance);
}

//+------------------------------------------------------------------+
bool OpenScheduledPosition()
{
   if(!TradingEnvironmentOK())
      return false;

   if(CountOpenPositions() >= MaxOpenPositions)
      return false;

   datetime currentBarTime = iTime(_Symbol, EntryTimeframe, 0);
   if(currentBarTime == 0 || currentBarTime == LastOpenBarTime)
      return false;

   if(LastOpenAttemptTime > 0 && TimeCurrent() - LastOpenAttemptTime < OpenEveryMinutes * 60)
      return false;

   double atr = BufferValue(HandleATR, 0, 1);
   if(atr == EMPTY_VALUE || atr <= 0.0)
      return false;

   int direction = (DirectionScore() >= 0 ? 1 : -1);
   CloseOpposite(direction);

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return false;

   double volume = NormalizeVolume(Lots);
   double stopDistance = ATRStopMultiplier * atr;
   double minStop = MinStopPoints * _Point;
   double maxStop = MaxStopPoints * _Point;
   stopDistance = MathMax(stopDistance, minStop);
   if(maxStop > 0.0)
      stopDistance = MathMin(stopDistance, maxStop);

   double entry = (direction > 0 ? tick.ask : tick.bid);
   double sl = 0.0;
   double tp = 0.0;

   if(direction > 0)
   {
      sl = entry - stopDistance;
      tp = entry + ATRTakeProfitMultiplier * atr;
   }
   else
   {
      sl = entry + stopDistance;
      tp = entry - ATRTakeProfitMultiplier * atr;
   }

   entry = NormalizePrice(entry);
   sl = NormalizePrice(sl);
   tp = NormalizePrice(tp);

   if(!StopsAreValid(entry, sl, tp))
      return false;

   double margin = 0.0;
   ENUM_ORDER_TYPE orderType = (direction > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   if(!OrderCalcMargin(orderType, _Symbol, volume, entry, margin))
      return false;

   if(AccountInfoDouble(ACCOUNT_MARGIN_FREE) <= margin * 1.10)
      return false;

   bool sent = false;
   if(direction > 0)
      sent = Trade.Buy(volume, _Symbol, 0.0, sl, tp, TradeComment);
   else
      sent = Trade.Sell(volume, _Symbol, 0.0, sl, tp, TradeComment);

   LastOpenAttemptTime = TimeCurrent();

   if(sent)
   {
      LastOpenBarTime = currentBarTime;
      PrintFormat("%s opened by timer: lot=%.2f score=%d sl=%.2f tp=%.2f",
                  direction > 0 ? "BUY" : "SELL", volume, DirectionScore(), sl, tp);
   }
   else
   {
      PrintFormat("Order failed: retcode=%u %s",
                  Trade.ResultRetcode(), Trade.ResultRetcodeDescription());
   }

   return sent;
}

//+------------------------------------------------------------------+
void ManagePositions()
{
   double atr = BufferValue(HandleATR, 0, 1);
   if(atr == EMPTY_VALUE || atr <= 0.0)
      return;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!Position.SelectByIndex(i))
         continue;

      if(Position.Symbol() != _Symbol || (ulong)Position.Magic() != MagicNumber)
         continue;

      ulong ticket = Position.Ticket();
      long type = Position.Type();
      double open = Position.PriceOpen();
      double sl = Position.StopLoss();
      double tp = Position.TakeProfit();
      datetime posTime = (datetime)Position.Time();

      if(MaxHoldMinutes > 0 && TimeCurrent() - posTime >= MaxHoldMinutes * 60)
      {
         Trade.PositionClose(ticket);
         continue;
      }

      if(sl <= 0.0 || tp <= 0.0)
         continue;

      double initialRisk = MathAbs(open - sl);
      if(initialRisk <= 0.0)
         continue;

      double current = (type == POSITION_TYPE_BUY ? tick.bid : tick.ask);
      double profitDistance = (type == POSITION_TYPE_BUY ? current - open : open - current);
      if(profitDistance <= 0.0)
         continue;

      double newSL = sl;

      if(UseBreakEven && profitDistance >= BreakEvenAtR * initialRisk)
      {
         double be = (type == POSITION_TYPE_BUY)
                     ? open + BreakEvenBufferPoints * _Point
                     : open - BreakEvenBufferPoints * _Point;

         if(type == POSITION_TYPE_BUY && be > newSL)
            newSL = be;

         if(type == POSITION_TYPE_SELL && be < newSL)
            newSL = be;
      }

      if(UseTrailingStop && profitDistance >= TrailStartR * initialRisk)
      {
         double trail = (type == POSITION_TYPE_BUY)
                        ? current - TrailATRMultiplier * atr
                        : current + TrailATRMultiplier * atr;

         if(type == POSITION_TYPE_BUY && trail > newSL)
            newSL = trail;

         if(type == POSITION_TYPE_SELL && trail < newSL)
            newSL = trail;
      }

      newSL = NormalizePrice(newSL);
      if(MathAbs(newSL - sl) >= 5.0 * _Point)
         Trade.PositionModify(ticket, newSL, tp);
   }
}

//+------------------------------------------------------------------+
int OnInit()
{
   if(!IsAllowedSymbol())
   {
      PrintFormat("This EA is XAUUSD-only. Current chart symbol is %s.", _Symbol);
      return INIT_FAILED;
   }

   if(RequireDemoAccount && AccountInfoInteger(ACCOUNT_TRADE_MODE) != ACCOUNT_TRADE_MODE_DEMO)
   {
      Print("This high-risk EA is configured for demo accounts only.");
      return INIT_FAILED;
   }

   Trade.SetExpertMagicNumber(MagicNumber);
   Trade.SetDeviationInPoints(SlippagePoints);
   Trade.SetTypeFillingBySymbol(_Symbol);

   HandleFastMA = iMA(_Symbol, EntryTimeframe, EMAFastPeriod, 0, MODE_EMA, PRICE_CLOSE);
   HandleSlowMA = iMA(_Symbol, EntryTimeframe, EMASlowPeriod, 0, MODE_EMA, PRICE_CLOSE);
   HandleRSI = iRSI(_Symbol, EntryTimeframe, RSIPeriod, PRICE_CLOSE);
   HandleMACD = iMACD(_Symbol, EntryTimeframe, MACDFast, MACDSlow, MACDSignal, PRICE_CLOSE);
   HandleATR = iATR(_Symbol, EntryTimeframe, ATRPeriod);

   if(HandleFastMA == INVALID_HANDLE ||
      HandleSlowMA == INVALID_HANDLE ||
      HandleRSI == INVALID_HANDLE ||
      HandleMACD == INVALID_HANDLE ||
      HandleATR == INVALID_HANDLE)
   {
      PrintFormat("Indicator initialization failed. LastError=%d", GetLastError());
      return INIT_FAILED;
   }

   EventSetTimer(MathMax(1, TimerSeconds));
   Print("XAU5M high-risk timer EA initialized. Demo/stress testing only.");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();

   if(HandleFastMA != INVALID_HANDLE)
      IndicatorRelease(HandleFastMA);
   if(HandleSlowMA != INVALID_HANDLE)
      IndicatorRelease(HandleSlowMA);
   if(HandleRSI != INVALID_HANDLE)
      IndicatorRelease(HandleRSI);
   if(HandleMACD != INVALID_HANDLE)
      IndicatorRelease(HandleMACD);
   if(HandleATR != INVALID_HANDLE)
      IndicatorRelease(HandleATR);
}

//+------------------------------------------------------------------+
void OnTimer()
{
   ManagePositions();
   OpenScheduledPosition();
}

//+------------------------------------------------------------------+
void OnTick()
{
   ManagePositions();
}
//+------------------------------------------------------------------+
