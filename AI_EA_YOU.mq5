//+------------------------------------------------------------------+
//|                                                    AI_EA_YOU.mq5 |
//|                       Simple XAUUSD Trend EA (EMA 9/50/200)       |
//+------------------------------------------------------------------+
#property copyright "2026"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

input string           InpSymbol              = "XAUUSD";
input ENUM_TIMEFRAMES  InpTimeframe           = PERIOD_M1;

input int              InpEMAFast             = 9;
input int              InpEMAMid              = 50;
input int              InpEMASlow             = 200;
input bool             InpUseTrailingStop     = true;
input int              InpTakeProfitPoints    = 50;
input int              InpTrailingStopPoints  = 10;

input double           InpRiskPercent         = 1.0;
input int              InpMaxSpreadPoints     = 3000;
input bool             InpOnePositionOnly     = true;
input bool             InpCloseOnReverse      = true;
input bool             InpForceMinLot         = true;
input bool             InpDebug               = true;
input ulong            InpMagic               = 26030701;

input int              InpStartHour           = 1;
input int              InpEndHour             = 23;

CTrade trade;

int      gFastHandle = INVALID_HANDLE;
int      gMidHandle  = INVALID_HANDLE;
int      gSlowHandle = INVALID_HANDLE;
string   gTradeSymbol = "";
const ENUM_TIMEFRAMES  TRADE_TF = PERIOD_M1;

//+------------------------------------------------------------------+
void DebugPrint(const string msg)
  {
   if(InpDebug)
      Print(msg);
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   gTradeSymbol = InpSymbol;
   if(gTradeSymbol=="" || gTradeSymbol=="AUTO")
      gTradeSymbol = _Symbol;

   if(!SymbolSelect(gTradeSymbol,true))
     {
      Print("Cannot select symbol: ",gTradeSymbol);
      return(INIT_FAILED);
     }

   gFastHandle = iMA(gTradeSymbol,TRADE_TF,InpEMAFast,0,MODE_EMA,PRICE_CLOSE);
   gMidHandle  = iMA(gTradeSymbol,TRADE_TF,InpEMAMid,0,MODE_EMA,PRICE_CLOSE);
   gSlowHandle = iMA(gTradeSymbol,TRADE_TF,InpEMASlow,0,MODE_EMA,PRICE_CLOSE);

   if(gFastHandle==INVALID_HANDLE || gMidHandle==INVALID_HANDLE || gSlowHandle==INVALID_HANDLE)
     {
      Print("Indicator handle creation failed.");
      return(INIT_FAILED);
     }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(20);
   if(InpTimeframe!=PERIOD_M1)
      DebugPrint("Info: EA is forced to M1. InpTimeframe is ignored.");
   if(!InpOnePositionOnly)
      DebugPrint("Info: one-position-only mode is forced ON. InpOnePositionOnly is ignored.");
   DebugPrint("EA ready. Symbol="+gTradeSymbol+" TF="+EnumToString(TRADE_TF));

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(gFastHandle!=INVALID_HANDLE) IndicatorRelease(gFastHandle);
   if(gMidHandle!=INVALID_HANDLE)  IndicatorRelease(gMidHandle);
   if(gSlowHandle!=INVALID_HANDLE) IndicatorRelease(gSlowHandle);
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   if(InpUseTrailingStop)
      ManageTrailingStop();

   if(!IsTradingHour())
     {
      DebugPrint("Skip: out of trading hour");
      return;
     }

   if(GetSpreadPoints()>InpMaxSpreadPoints)
     {
      DebugPrint("Skip: spread too high. spread="+IntegerToString(GetSpreadPoints())+
                 " max="+IntegerToString(InpMaxSpreadPoints));
      return;
     }

   double fast[1], mid[1], slow[1];
   if(CopyBuffer(gFastHandle,0,0,1,fast)<1)  return;
   if(CopyBuffer(gMidHandle,0,0,1,mid)<1)    return;
   if(CopyBuffer(gSlowHandle,0,0,1,slow)<1)  return;

   double ask = SymbolInfoDouble(gTradeSymbol,SYMBOL_ASK);
   double bid = SymbolInfoDouble(gTradeSymbol,SYMBOL_BID);
   double refPrice = (ask + bid) * 0.5;

   bool buySignal  = (refPrice > slow[0] && fast[0] > mid[0] && mid[0] > slow[0]);
   bool sellSignal = (refPrice < slow[0] && fast[0] < mid[0] && mid[0] < slow[0]);

   int posType = -1;
   bool hasPos = HasPosition(posType);

   if(hasPos && InpCloseOnReverse)
     {
      if((posType==POSITION_TYPE_BUY && sellSignal) || (posType==POSITION_TYPE_SELL && buySignal))
        {
         if(!trade.PositionClose(gTradeSymbol))
           {
            Print("Close on reverse failed. RetCode=",trade.ResultRetcode()," ",trade.ResultRetcodeDescription());
            return;
           }
         hasPos = false;
        }
     }

   if(hasPos)
     {
      DebugPrint("Skip: already has position (one order at a time)");
      return;
     }

   int    digits = (int)SymbolInfoInteger(gTradeSymbol,SYMBOL_DIGITS);
   double point = SymbolInfoDouble(gTradeSymbol,SYMBOL_POINT);
   if(point<=0.0)
      return;

   double slDistance = (double)InpTrailingStopPoints * point;
   double tpDistance = (double)InpTakeProfitPoints * point;
   double lots = CalculateLots(slDistance);
   if(lots<=0.0)
     {
      DebugPrint("Skip: lot size <= 0 (risk too low or symbol settings)");
      return;
     }

   if(buySignal)
     {
      double sl = NormalizeDouble(ask - slDistance,digits);
      double tp = NormalizeDouble(ask + tpDistance,digits);
      if(!trade.Buy(lots,gTradeSymbol,0.0,sl,tp,"AI_EA_YOU BUY"))
         Print("Buy failed. RetCode=",trade.ResultRetcode()," ",trade.ResultRetcodeDescription());
     }

   if(sellSignal)
     {
      double sl = NormalizeDouble(bid + slDistance,digits);
      double tp = NormalizeDouble(bid - tpDistance,digits);
      if(!trade.Sell(lots,gTradeSymbol,0.0,sl,tp,"AI_EA_YOU SELL"))
         Print("Sell failed. RetCode=",trade.ResultRetcode()," ",trade.ResultRetcodeDescription());
     }

  }

//+------------------------------------------------------------------+
bool IsTradingHour()
  {
   MqlDateTime dt;
   TimeToStruct(TimeTradeServer(),dt);

   if(InpStartHour==InpEndHour)
      return(true);

   if(InpStartHour<InpEndHour)
      return(dt.hour>=InpStartHour && dt.hour<InpEndHour);

   return(dt.hour>=InpStartHour || dt.hour<InpEndHour);
  }

//+------------------------------------------------------------------+
int GetSpreadPoints()
  {
   double ask = SymbolInfoDouble(gTradeSymbol,SYMBOL_ASK);
   double bid = SymbolInfoDouble(gTradeSymbol,SYMBOL_BID);
   double point = SymbolInfoDouble(gTradeSymbol,SYMBOL_POINT);
   if(point<=0.0)
      return(0);
   return((int)MathRound((ask-bid)/point));
  }

//+------------------------------------------------------------------+
bool HasPosition(int &type)
  {
   type = -1;
   int total = PositionsTotal();
   for(int i=total-1; i>=0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      string sym = PositionGetString(POSITION_SYMBOL);
      long   mg  = PositionGetInteger(POSITION_MAGIC);
      if(sym==gTradeSymbol && (ulong)mg==InpMagic)
        {
         type = (int)PositionGetInteger(POSITION_TYPE);
         return(true);
        }
     }
   return(false);
  }

//+------------------------------------------------------------------+
double CalculateLots(double slDistancePrice)
  {
   if(slDistancePrice<=0.0)
      return(0.0);

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   if(balance<=0.0 || equity<=0.0 || InpRiskPercent<=0.0)
      return(0.0);

   // Use the smaller capital base for conservative risk sizing.
   double capital = MathMin(balance,equity);
   double riskMoney = capital * (InpRiskPercent/100.0);
   if(riskMoney<=0.0)
      return(0.0);

   double tickSize  = SymbolInfoDouble(gTradeSymbol,SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(gTradeSymbol,SYMBOL_TRADE_TICK_VALUE);
   if(tickSize<=0.0 || tickValue<=0.0)
      return(0.0);

   double moneyPerLot = (slDistancePrice/tickSize) * tickValue;
   if(moneyPerLot<=0.0)
      return(0.0);

   double lots = riskMoney / moneyPerLot;
   if(lots<=0.0)
      return(0.0);

   double minLot  = SymbolInfoDouble(gTradeSymbol,SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(gTradeSymbol,SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(gTradeSymbol,SYMBOL_VOLUME_STEP);

   if(lotStep<=0.0)
      lotStep = minLot;

   lots = MathFloor(lots/lotStep)*lotStep;
   if(lots<minLot)
     {
      // Force min lot only when risk budget can actually cover min-lot stop loss.
      if(InpForceMinLot && riskMoney >= (moneyPerLot * minLot))
         lots = minLot;
      else
         return(0.0);
     }
   lots = MathMin(maxLot,lots);

   int volDigits = 0;
   double stepCheck = lotStep;
   while(stepCheck < 1.0 && volDigits < 8)
     {
      stepCheck *= 10.0;
      volDigits++;
     }

   return(NormalizeDouble(lots,volDigits));
  }

//+------------------------------------------------------------------+
void ManageTrailingStop()
  {
   if(InpTrailingStopPoints<=0)
      return;

   double point = SymbolInfoDouble(gTradeSymbol,SYMBOL_POINT);
   if(point<=0.0)
      return;

   int digits = (int)SymbolInfoInteger(gTradeSymbol,SYMBOL_DIGITS);
   double bid = SymbolInfoDouble(gTradeSymbol,SYMBOL_BID);
   double ask = SymbolInfoDouble(gTradeSymbol,SYMBOL_ASK);

   int total = PositionsTotal();
   for(int i=total-1; i>=0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      string sym = PositionGetString(POSITION_SYMBOL);
      long   mg  = PositionGetInteger(POSITION_MAGIC);
      if(sym!=gTradeSymbol || (ulong)mg!=InpMagic)
         continue;

      long posType = PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currSL = PositionGetDouble(POSITION_SL);
      double currTP = PositionGetDouble(POSITION_TP);
      if(openPrice<=0.0)
         continue;

      if(posType==POSITION_TYPE_BUY)
        {
         if((bid-openPrice) <= ((double)InpTrailingStopPoints * point))
            continue;
         double newSL = NormalizeDouble(bid - ((double)InpTrailingStopPoints * point),digits);
         if(currSL==0.0 || newSL>currSL)
            trade.PositionModify(gTradeSymbol,newSL,currTP);
        }
      else if(posType==POSITION_TYPE_SELL)
        {
         if((openPrice-ask) <= ((double)InpTrailingStopPoints * point))
            continue;
         double newSL = NormalizeDouble(ask + ((double)InpTrailingStopPoints * point),digits);
         if(currSL==0.0 || newSL<currSL)
            trade.PositionModify(gTradeSymbol,newSL,currTP);
        }
     }
  }
//+------------------------------------------------------------------+
