//+------------------------------------------------------------------+
//|                                                AI_EA_YOU_BTC.mq5 |
//|                 Simple BTCUSD Direction EA (Prev-Candle Price)    |
//+------------------------------------------------------------------+
#property copyright "2026"
#property version   "1.10"
#property strict

#include <Trade/Trade.mqh>

input string           InpSymbol              = "BTCUSD";
input ENUM_TIMEFRAMES  InpTimeframe           = PERIOD_M1;

input bool             InpUseTrailingStop     = true;
input int              InpMaxPositions        = 3;
input int              InpAddProfitPoints     = 3000;
input int              InpTakeProfitPoints    = 6000;
input int              InpTrailingStopPoints  = 2000;
input int              InpCutLossPoints       = 5000;
input double           InpCutLossPercent      = 5.0;
input int              InpRescueTriggerPoints = 3500;
input double           InpRescueLotMultiplier = 1.5;
input bool             InpRescueScaleDownWithBalance = true;
input double           InpRescueCloseNetMoney = 0.0;

input double           InpRiskPercent         = 0.5;
input int              InpMaxSpreadPoints     = 30000;
input bool             InpOnePositionOnly     = true;
input bool             InpCloseOnReverse      = true;
input bool             InpForceMinLot         = true;
input bool             InpDebug               = true;
input ulong            InpMagic               = 26030702;

input int              InpStartHour           = 0;
input int              InpEndHour             = 0;

CTrade trade;

string   gTradeSymbol = "";
const ENUM_TIMEFRAMES  TRADE_TF = PERIOD_M1;

//+------------------------------------------------------------------+
void DebugPrint(const string msg)
  {
   if(InpDebug)
      Print(msg);
  }

//+------------------------------------------------------------------+
int GetMinStopPoints()
  {
   long stopsLevel  = SymbolInfoInteger(gTradeSymbol,SYMBOL_TRADE_STOPS_LEVEL);
   long freezeLevel = SymbolInfoInteger(gTradeSymbol,SYMBOL_TRADE_FREEZE_LEVEL);
   if(stopsLevel<0)  stopsLevel = 0;
   if(freezeLevel<0) freezeLevel = 0;
   return((int)MathMax(stopsLevel,freezeLevel) + 1);
  }

//+------------------------------------------------------------------+
bool AreStopsValid(const bool isBuy,const double sl,const double tp,const double bid,const double ask,const double minDistPrice)
  {
   if(isBuy)
     {
      if(sl>0.0 && (bid-sl)<=minDistPrice) return(false);
      if(tp>0.0 && (tp-ask)<=minDistPrice) return(false);
      return(true);
     }

   if(sl>0.0 && (sl-ask)<=minDistPrice) return(false);
   if(tp>0.0 && (bid-tp)<=minDistPrice) return(false);
   return(true);
  }

//+------------------------------------------------------------------+
double NormalizePriceToTick(const double price)
  {
   double tickSize = SymbolInfoDouble(gTradeSymbol,SYMBOL_TRADE_TICK_SIZE);
   int digits = (int)SymbolInfoInteger(gTradeSymbol,SYMBOL_DIGITS);
   if(tickSize<=0.0)
      return(NormalizeDouble(price,digits));

   double steps = MathRound(price/tickSize);
   double normalized = steps*tickSize;
   return(NormalizeDouble(normalized,digits));
  }

//+------------------------------------------------------------------+
double NormalizeVolumeToStep(const double rawLots)
  {
   double minLot  = SymbolInfoDouble(gTradeSymbol,SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(gTradeSymbol,SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(gTradeSymbol,SYMBOL_VOLUME_STEP);
   if(minLot<=0.0 || maxLot<=0.0)
      return(0.0);
   if(lotStep<=0.0)
      lotStep = minLot;

   double lots = MathMax(minLot,MathMin(maxLot,rawLots));
   lots = MathFloor(lots/lotStep)*lotStep;
   if(lots<minLot)
      lots = minLot;

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
double GetDynamicLotsByBalance()
  {
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double rawLots = 0.01;

   // Requested ladder example: 1000 => 0.02, 3000 => 0.03, 5000 => 0.04, ...
   if(balance>=1000.0)
     {
      int tier = 1 + (int)MathFloor((balance-1000.0)/2000.0);
      rawLots = 0.01 + (0.01 * tier);
     }

   return(NormalizeVolumeToStep(rawLots));
  }

//+------------------------------------------------------------------+
bool IsRescueComment(const string comment)
  {
   return(StringFind(comment,"AI_EA_YOU RESCUE",0)==0);
  }

//+------------------------------------------------------------------+
bool ClosePositionByTicket(const ulong ticket)
  {
   if(ticket==0)
      return(false);
   if(!PositionSelectByTicket(ticket))
      return(false);
   return(trade.PositionClose(ticket));
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

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(20);
   if(InpTimeframe!=PERIOD_M1)
      DebugPrint("Info: EA is forced to M1. InpTimeframe is ignored.");
   if(!InpOnePositionOnly)
      DebugPrint("Info: one-position-only mode is forced ON. InpOnePositionOnly is ignored.");
   DebugPrint("Broker min stop points="+IntegerToString(GetMinStopPoints()));
   DebugPrint("EA ready. Symbol="+gTradeSymbol+" TF="+EnumToString(TRADE_TF));

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   if(InpUseTrailingStop)
      ManageTrailingStop();

   if(CutLosingPositionsByPoints())
      return;

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

   double ask = SymbolInfoDouble(gTradeSymbol,SYMBOL_ASK);
   double bid = SymbolInfoDouble(gTradeSymbol,SYMBOL_BID);
   double refPrice = (ask + bid) * 0.5;
   double prevClose = iClose(gTradeSymbol,TRADE_TF,1);
   if(prevClose<=0.0)
      return;

   bool buySignal  = (refPrice > prevClose);
   bool sellSignal = (refPrice < prevClose);
   if(!buySignal && !sellSignal)
      return;

   double point = SymbolInfoDouble(gTradeSymbol,SYMBOL_POINT);
   if(point<=0.0)
      return;

   int maxPositions = MathMax(1,InpMaxPositions);
   int addProfitPoints = MathMax(1,InpAddProfitPoints);
   int posCount = 0;
   int basketType = -1;
   double latestOpenPrice = 0.0;
   datetime latestOpenTime = 0;
   double floatingProfit = 0.0;
   ulong rescueTicket = 0;
   int rescueType = -1;
   double rescueProfit = 0.0;
   ulong rescuePairTicket = 0;
   double rescuePairProfit = 0.0;
   bool hasRescuePair = false;
   ulong worstLosingTicket = 0;
   int worstLosingType = -1;
   double worstLosingPoints = 0.0;
   double worstLosingLots = 0.0;

   int total = PositionsTotal();
   for(int i=total-1; i>=0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;

      string sym = PositionGetString(POSITION_SYMBOL);
      long mg = PositionGetInteger(POSITION_MAGIC);
      if(sym!=gTradeSymbol || (ulong)mg!=InpMagic)
         continue;

      string comment = PositionGetString(POSITION_COMMENT);
      int pType = (int)PositionGetInteger(POSITION_TYPE);
      double pProfit = PositionGetDouble(POSITION_PROFIT);
      double pLots = PositionGetDouble(POSITION_VOLUME);
      double pOpen = PositionGetDouble(POSITION_PRICE_OPEN);
      datetime pTime = (datetime)PositionGetInteger(POSITION_TIME);
      posCount++;
      floatingProfit += pProfit;

      if(IsRescueComment(comment))
        {
         rescueTicket = ticket;
         rescueType = pType;
         rescueProfit = pProfit;
         continue;
        }

      if(basketType==-1)
         basketType = pType;
      else if(basketType!=pType)
         basketType = -2;

      double adversePoints = 0.0;
      if(pType==POSITION_TYPE_BUY)
         adversePoints = (pOpen-bid)/point;
      else if(pType==POSITION_TYPE_SELL)
         adversePoints = (ask-pOpen)/point;

      if(adversePoints>worstLosingPoints)
        {
         worstLosingPoints = adversePoints;
         worstLosingTicket = ticket;
         worstLosingType = pType;
         worstLosingLots = pLots;
        }

      if(pTime>=latestOpenTime)
        {
         latestOpenTime = pTime;
         latestOpenPrice = pOpen;
        }
     }

   if(posCount>0 && InpCutLossPercent>0.0)
     {
      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      if(balance>0.0)
        {
         double lossPercent = (-floatingProfit / balance) * 100.0;
         if(lossPercent >= InpCutLossPercent)
           {
            DebugPrint("CutLoss triggered: floating loss="+DoubleToString(lossPercent,2)+"%");
            if(!CloseAllEaPositions())
               Print("CutLoss close all failed");
            return;
           }
        }
     }

   if(rescueTicket!=0)
     {
      for(int i=total-1; i>=0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket==0 || ticket==rescueTicket)
            continue;
         if(!PositionSelectByTicket(ticket))
            continue;
         string sym = PositionGetString(POSITION_SYMBOL);
         long mg = PositionGetInteger(POSITION_MAGIC);
         if(sym!=gTradeSymbol || (ulong)mg!=InpMagic)
            continue;
         string comment = PositionGetString(POSITION_COMMENT);
         if(IsRescueComment(comment))
            continue;
         int pType = (int)PositionGetInteger(POSITION_TYPE);
         if(pType==rescueType)
            continue;
         double pProfit = PositionGetDouble(POSITION_PROFIT);
         if(!hasRescuePair || pProfit<rescuePairProfit)
           {
            hasRescuePair = true;
            rescuePairTicket = ticket;
            rescuePairProfit = pProfit;
           }
        }

      if(hasRescuePair)
        {
         double netPair = rescueProfit + rescuePairProfit;
         if(netPair >= InpRescueCloseNetMoney)
           {
            bool ok1 = ClosePositionByTicket(rescueTicket);
            bool ok2 = ClosePositionByTicket(rescuePairTicket);
            if(ok1 && ok2)
               DebugPrint("Rescue pair closed. Net="+DoubleToString(netPair,2));
            else
               Print("Rescue pair close failed");
           }
        }
      return;
     }

   if(worstLosingTicket!=0 && worstLosingPoints>=InpRescueTriggerPoints)
     {
      double rescueBaseLots = worstLosingLots;
      if(InpRescueScaleDownWithBalance)
        {
         double dynamicLots = GetDynamicLotsByBalance();
         if(dynamicLots>0.0)
            rescueBaseLots = MathMin(rescueBaseLots,dynamicLots);
        }

      double rescueLots = NormalizeVolumeToStep(rescueBaseLots * MathMax(0.1,InpRescueLotMultiplier));
      if(rescueLots>0.0)
        {
         if(worstLosingType==POSITION_TYPE_BUY)
           {
            if(!trade.Sell(rescueLots,gTradeSymbol,0.0,0.0,0.0,"AI_EA_YOU RESCUE"))
               Print("Rescue SELL failed. RetCode=",trade.ResultRetcode()," ",trade.ResultRetcodeDescription());
            else
               DebugPrint("Rescue SELL opened for losing BUY. base="+
                          DoubleToString(rescueBaseLots,2)+
                          " lot="+DoubleToString(rescueLots,2));
           }
         else if(worstLosingType==POSITION_TYPE_SELL)
           {
            if(!trade.Buy(rescueLots,gTradeSymbol,0.0,0.0,0.0,"AI_EA_YOU RESCUE"))
               Print("Rescue BUY failed. RetCode=",trade.ResultRetcode()," ",trade.ResultRetcodeDescription());
            else
               DebugPrint("Rescue BUY opened for losing SELL. base="+
                          DoubleToString(rescueBaseLots,2)+
                          " lot="+DoubleToString(rescueLots,2));
           }
        }
      else
        {
         DebugPrint("Rescue skipped: invalid rescue lot size");
        }
      return;
     }

   if(posCount>=maxPositions)
     {
      DebugPrint("Skip: max positions reached ("+IntegerToString(maxPositions)+")");
      return;
     }

   if(posCount>0)
     {
      if(basketType==-2)
        {
         DebugPrint("Skip: mixed BUY/SELL basket detected");
         return;
        }
      if((basketType==POSITION_TYPE_BUY && !buySignal) || (basketType==POSITION_TYPE_SELL && !sellSignal))
        {
         DebugPrint("Skip: existing basket direction is opposite to signal");
         return;
        }

      double progressPoints = 0.0;
      if(basketType==POSITION_TYPE_BUY)
         progressPoints = (bid - latestOpenPrice) / point;
      else if(basketType==POSITION_TYPE_SELL)
         progressPoints = (latestOpenPrice - ask) / point;

      if(progressPoints < addProfitPoints)
        {
         DebugPrint("Skip: last position profit < "+IntegerToString(addProfitPoints)+" points");
         return;
        }
     }

   int minStopPoints = GetMinStopPoints();
   int tpPoints = MathMax(InpTakeProfitPoints,minStopPoints);
   double tpDistance = (double)tpPoints * point;
   double minDistPrice = (double)minStopPoints * point;
   double lots = GetDynamicLotsByBalance();
   if(lots<=0.0)
     {
      DebugPrint("Skip: invalid dynamic lot size");
      return;
     }

   if(buySignal)
     {
      double sl = 0.0;
      double tp = NormalizePriceToTick(ask + tpDistance);
      if(!AreStopsValid(true,sl,tp,bid,ask,minDistPrice))
        {
         DebugPrint("Skip BUY: invalid stop distance for broker rules");
         return;
        }
      if(!trade.Buy(lots,gTradeSymbol,0.0,sl,tp,"AI_EA_YOU BUY"))
         Print("Buy failed. RetCode=",trade.ResultRetcode()," ",trade.ResultRetcodeDescription());
     }

   if(sellSignal)
     {
      double sl = 0.0;
      double tp = NormalizePriceToTick(bid - tpDistance);
      if(!AreStopsValid(false,sl,tp,bid,ask,minDistPrice))
        {
         DebugPrint("Skip SELL: invalid stop distance for broker rules");
         return;
        }
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
bool CloseAllEaPositions()
  {
   bool ok = true;
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

      if(!trade.PositionClose(ticket))
        {
         ok = false;
         Print("Close all failed. Ticket=",ticket," RetCode=",trade.ResultRetcode()," ",trade.ResultRetcodeDescription());
        }
     }
   return(ok);
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
   int minStopPoints = GetMinStopPoints();
   int trailPoints = MathMax(InpTrailingStopPoints,minStopPoints);
   double minDistPrice = (double)minStopPoints * point;

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
         if((bid-openPrice) <= ((double)trailPoints * point))
            continue;
         double newSL = NormalizePriceToTick(bid - ((double)trailPoints * point));
         if((bid-newSL)<=minDistPrice)
            continue;
         if(currSL==0.0 || newSL>currSL)
            trade.PositionModify(gTradeSymbol,newSL,currTP);
        }
      else if(posType==POSITION_TYPE_SELL)
        {
         if((openPrice-ask) <= ((double)trailPoints * point))
            continue;
         double newSL = NormalizePriceToTick(ask + ((double)trailPoints * point));
         if((newSL-ask)<=minDistPrice)
            continue;
         if(currSL==0.0 || newSL<currSL)
            trade.PositionModify(gTradeSymbol,newSL,currTP);
        }
     }
  }
//+------------------------------------------------------------------+
bool CutLosingPositionsByPoints()
  {
   if(InpCutLossPoints<=0)
      return(false);

   double point = SymbolInfoDouble(gTradeSymbol,SYMBOL_POINT);
   if(point<=0.0)
      return(false);

   double bid = SymbolInfoDouble(gTradeSymbol,SYMBOL_BID);
   double ask = SymbolInfoDouble(gTradeSymbol,SYMBOL_ASK);
   bool closedAny = false;

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
      if(openPrice<=0.0)
         continue;

      double adversePoints = 0.0;
      if(posType==POSITION_TYPE_BUY)
         adversePoints = (openPrice-bid)/point;
      else if(posType==POSITION_TYPE_SELL)
         adversePoints = (ask-openPrice)/point;
      else
         continue;

      if(adversePoints < (double)InpCutLossPoints)
         continue;

      if(trade.PositionClose(ticket))
        {
         closedAny = true;
         DebugPrint("Cut by points. Ticket="+(string)ticket+
                    " adversePoints="+DoubleToString(adversePoints,1));
        }
      else
        {
         Print("Cut by points failed. Ticket=",ticket,
               " RetCode=",trade.ResultRetcode()," ",trade.ResultRetcodeDescription());
        }
     }

   return(closedAny);
  }
//+------------------------------------------------------------------+
