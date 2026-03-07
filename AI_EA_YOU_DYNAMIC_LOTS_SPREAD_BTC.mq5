//+------------------------------------------------------------------+
//|                            AI_EA_YOU_DYNAMIC_LOTS_SPREAD_BTC.mq5 |
//|     BTCUSD M1 Dynamic Lots + Spread/Commission Cost-Aware EA      |
//+------------------------------------------------------------------+
#property copyright "2026"
#property version   "1.21"
#property strict

#include <Trade/Trade.mqh>

input string           InpSymbol              = "BTCUSD";
input ENUM_TIMEFRAMES  InpTimeframe           = PERIOD_M1;

input bool             InpUseTrailingStop     = true;
input int              InpMaxPositions        = 4;
input int              InpAddProfitPoints     = 3000;
input int              InpTakeProfitPoints    = 8000;
input int              InpTrailingStopPoints  = 3500;
input int              InpMinLockProfitPoints = 2500;
input bool             InpUseProfitRetraceExit = true;
input int              InpProfitRetraceStartPoints = 4000;
input int              InpProfitRetraceGivebackPoints = 1500;
input int              InpCutLossPoints       = 7000;
input double           InpCutLossPercent      = 6.0;
input int              InpRescueTriggerPoints = 5000;
input double           InpRescueLotMultiplier = 1.5;
input bool             InpRescueScaleDownWithBalance = true;
input double           InpRescueCloseNetMoney = 0.0;

input double           InpRiskPercent         = 0.50;
input bool             InpUseAtrForSLTP       = true;
input int              InpAtrPeriod           = 14;
input double           InpAtrSLMultiplier     = 1.8;
input double           InpAtrTPMultiplier     = 3.5;
input int              InpAtrMinPoints        = 2500;
input bool             InpUseAntiMartingale   = true;
input double           InpWinStepMultiplier   = 1.25;
input int              InpMaxWinStreakSteps   = 3;
input bool             InpUseDrawdownThrottle = true;
input double           InpDDLevel1Percent     = 6.0;
input double           InpDDLevel1RiskFactor  = 0.6;
input double           InpDDLevel2Percent     = 12.0;
input double           InpDDLevel2RiskFactor  = 0.2;
input double           InpMinEffectiveRiskPercent = 0.08;
input int              InpMaxSpreadPoints     = 60000;
input bool             InpUseSpreadEdgeFilter = true;
input double           InpCommissionPerLotPerSideUSD = 3.5;
input int              InpEstimatedSlippagePointsRoundTrip = 60;
input int              InpMinNetTPAfterCostPoints = 2000;
input double           InpMinTPtoCostRatio    = 1.6;
input bool             InpOnePositionOnly     = true;
input bool             InpCloseOnReverse      = true;
input bool             InpForceMinLot         = true;
input bool             InpForceMinLotAlways   = true;
input bool             InpDebug               = true;
input ulong            InpMagic               = 26030721;
input bool             InpEnableMilestoneTimer = true;
input bool             InpMilestoneUseEquity   = false;
input int              InpMilestoneStep        = 1000;
input int              InpMilestoneMax         = 1000000;

input int              InpStartHour           = 0;
input int              InpEndHour             = 0;

CTrade trade;

string   gTradeSymbol = "";
const ENUM_TIMEFRAMES  TRADE_TF = PERIOD_M1;
int      gAtrHandle = INVALID_HANDLE;
int      gWinStreak = 0;
double   gPeakEquity = 0.0;
ulong    gLastProcessedDeal = 0;
datetime gEAStartTime = 0;
int      gLastMilestoneReported = 0;
double   gMilestoneStartValue = 0.0;
ulong    gTrackTickets[];
double   gTrackBestPoints[];

double GetDynamicSLDistancePrice();
double GetDynamicTPDistancePrice(const double slDistancePrice);
double GetEffectiveRiskPercent();
double CalculateLots(double slDistancePrice,const double riskPercent);
void UpdateMilestoneComment();
bool ManageProfitRetraceExit();
void CleanupTrackedTickets();
int FindTrackedTicketIndex(const ulong ticket);
void UpsertTrackedBestPoints(const ulong ticket,const double currentPoints);
double GetRoundTripCostPoints(const double lots);
bool IsEntryCostEfficient(const double lots,const double tpDistance,const double point,double &costPoints,double &tpPoints,double &netTpPoints);

//+------------------------------------------------------------------+
void DebugPrint(const string msg)
  {
   if(InpDebug)
      Print(msg);
  }

//+------------------------------------------------------------------+
string FormatElapsed(const datetime fromTime,const datetime toTime)
  {
   int sec = (int)MathMax(0,toTime-fromTime);
   int d = sec / 86400;
   sec %= 86400;
   int h = sec / 3600;
   sec %= 3600;
   int m = sec / 60;
   int s = sec % 60;

   return(IntegerToString(d)+"d "+
          IntegerToString(h)+"h "+
          IntegerToString(m)+"m "+
          IntegerToString(s)+"s");
  }

//+------------------------------------------------------------------+
void TrackMilestoneTimer()
  {
   if(!InpEnableMilestoneTimer)
      return;

   int step = MathMax(1,InpMilestoneStep);
   int maxTarget = MathMax(step,InpMilestoneMax);
   double metric = InpMilestoneUseEquity ? AccountInfoDouble(ACCOUNT_EQUITY)
                                         : AccountInfoDouble(ACCOUNT_BALANCE);
   double profitUsd = metric - gMilestoneStartValue;
   int currentProfit = (int)MathFloor(profitUsd);

   int nextTarget = gLastMilestoneReported + step;
   if(nextTarget<step)
      nextTarget = step;

   while(nextTarget<=maxTarget && currentProfit>=nextTarget)
     {
      string elapsed = FormatElapsed(gEAStartTime,TimeCurrent());
      string metricName = InpMilestoneUseEquity ? "equity" : "balance";
      Print("Profit milestone reached +",nextTarget," USD",
            " | elapsed=",elapsed,
            " | metric=",metricName,
            " | currentProfit=",DoubleToString(profitUsd,2),
            " | started=",TimeToString(gEAStartTime,TIME_DATE|TIME_SECONDS));
     gLastMilestoneReported = nextTarget;
      nextTarget += step;
     }
  }

//+------------------------------------------------------------------+
void UpdateMilestoneComment()
  {
   if(!InpEnableMilestoneTimer)
     {
      Comment("");
      return;
     }

   int step = MathMax(1,InpMilestoneStep);
   int maxTarget = MathMax(step,InpMilestoneMax);
   double metric = InpMilestoneUseEquity ? AccountInfoDouble(ACCOUNT_EQUITY)
                                         : AccountInfoDouble(ACCOUNT_BALANCE);
   double profitUsd = metric - gMilestoneStartValue;
   int nextTarget = gLastMilestoneReported + step;
   if(nextTarget<step)
      nextTarget = step;
   if(nextTarget>maxTarget)
      nextTarget = maxTarget;

   Comment("AI_EA_YOU_DYNAMIC_LOTS\n",
           "Profit from start: ",DoubleToString(profitUsd,2)," USD\n",
           "Next milestone: +",IntegerToString(nextTarget)," USD\n",
           "Elapsed: ",FormatElapsed(gEAStartTime,TimeCurrent()));
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
   double slDistancePrice = GetDynamicSLDistancePrice();
   double effRiskPercent = GetEffectiveRiskPercent();
   if(effRiskPercent<=0.0)
      return(0.0);
   return(CalculateLots(slDistancePrice,effRiskPercent));
  }

//+------------------------------------------------------------------+
double GetAtrPrice()
  {
   if(!InpUseAtrForSLTP || gAtrHandle==INVALID_HANDLE)
      return(0.0);

   double atrBuf[1];
   if(CopyBuffer(gAtrHandle,0,1,1,atrBuf)<=0)
      return(0.0);

   if(atrBuf[0]<=0.0)
      return(0.0);

   return(atrBuf[0]);
  }

//+------------------------------------------------------------------+
double GetDynamicSLDistancePrice()
  {
   double point = SymbolInfoDouble(gTradeSymbol,SYMBOL_POINT);
   if(point<=0.0)
      return(0.0);

   int minStopPoints = GetMinStopPoints();
   int minSlPoints = MathMax(minStopPoints,InpAtrMinPoints);

   if(!InpUseAtrForSLTP)
      return((double)minSlPoints * point);

   double atr = GetAtrPrice();
   if(atr<=0.0)
      return((double)minSlPoints * point);

   double atrSl = atr * MathMax(0.1,InpAtrSLMultiplier);
   double minSl = (double)minSlPoints * point;
   return(MathMax(atrSl,minSl));
  }

//+------------------------------------------------------------------+
double GetDynamicTPDistancePrice(const double slDistancePrice)
  {
   double point = SymbolInfoDouble(gTradeSymbol,SYMBOL_POINT);
   if(point<=0.0)
      return(0.0);

   double staticTp = (double)MathMax(1,InpTakeProfitPoints) * point;
   if(!InpUseAtrForSLTP)
      return(staticTp);

   double atr = GetAtrPrice();
   if(atr<=0.0)
      return(staticTp);

   double atrTp = atr * MathMax(0.1,InpAtrTPMultiplier);
   return(MathMax(staticTp,MathMax(atrTp,slDistancePrice)));
  }

//+------------------------------------------------------------------+
double GetEffectiveRiskPercent()
  {
   double risk = MathMax(0.0,InpRiskPercent);
   if(risk<=0.0)
      return(0.0);

   if(InpUseAntiMartingale)
     {
      int steps = MathMax(0,MathMin(gWinStreak,InpMaxWinStreakSteps));
      risk *= MathPow(MathMax(1.0,InpWinStepMultiplier),steps);
     }

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity>gPeakEquity)
      gPeakEquity = equity;

   if(InpUseDrawdownThrottle && gPeakEquity>0.0)
     {
      double ddPercent = ((gPeakEquity-equity)/gPeakEquity)*100.0;
      if(ddPercent>=InpDDLevel2Percent)
         risk *= MathMax(0.0,InpDDLevel2RiskFactor);
      else if(ddPercent>=InpDDLevel1Percent)
         risk *= MathMax(0.0,InpDDLevel1RiskFactor);
     }

   risk = MathMax(risk,MathMax(0.01,InpMinEffectiveRiskPercent));
   return(risk);
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
   gEAStartTime = TimeCurrent();
   gLastMilestoneReported = 0;

   if(InpEnableMilestoneTimer)
     {
      int step = MathMax(1,InpMilestoneStep);
      int maxTarget = MathMax(step,InpMilestoneMax);
      double metric = InpMilestoneUseEquity ? AccountInfoDouble(ACCOUNT_EQUITY)
                                            : AccountInfoDouble(ACCOUNT_BALANCE);
      gMilestoneStartValue = metric;
      gLastMilestoneReported = 0;

      string metricName = InpMilestoneUseEquity ? "equity" : "balance";
      Print("Profit milestone timer started. metric=",metricName,
            " startValue=",DoubleToString(gMilestoneStartValue,2),
            " targetStepUSD=",IntegerToString(step),
            " targetMaxUSD=",IntegerToString(maxTarget),
            " nextTargetProfitUSD=",IntegerToString(step),
            " startTime=",TimeToString(gEAStartTime,TIME_DATE|TIME_SECONDS));
     }

   gPeakEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   gWinStreak = 0;
   gLastProcessedDeal = 0;
   ArrayResize(gTrackTickets,0);
   ArrayResize(gTrackBestPoints,0);

   gAtrHandle = iATR(gTradeSymbol,TRADE_TF,MathMax(2,InpAtrPeriod));
   if(gAtrHandle==INVALID_HANDLE)
     {
      Print("Cannot create ATR handle for ",gTradeSymbol);
      return(INIT_FAILED);
     }
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
   if(gAtrHandle!=INVALID_HANDLE)
      IndicatorRelease(gAtrHandle);
   ArrayResize(gTrackTickets,0);
   ArrayResize(gTrackBestPoints,0);
   Comment("");
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   TrackMilestoneTimer();
   UpdateMilestoneComment();

   if(InpUseTrailingStop)
      ManageTrailingStop();

   if(ManageProfitRetraceExit())
      return;

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
   double minDistPrice = (double)minStopPoints * point;
   double slDistance = GetDynamicSLDistancePrice();
   double tpDistance = GetDynamicTPDistancePrice(slDistance);
   double effRiskPercent = GetEffectiveRiskPercent();
   if(effRiskPercent<=0.0)
     {
      DebugPrint("Skip: effective risk throttled to 0");
      return;
     }

   double lots = CalculateLots(slDistance,effRiskPercent);
   if(lots<=0.0)
     {
      DebugPrint("Skip: invalid dynamic lot size");
      return;
     }

   if(InpUseSpreadEdgeFilter)
     {
      double costPoints = 0.0;
      double tpPoints = 0.0;
      double netTpPoints = 0.0;
      if(!IsEntryCostEfficient(lots,tpDistance,point,costPoints,tpPoints,netTpPoints))
        {
         DebugPrint("Skip: cost edge weak. cost="+DoubleToString(costPoints,1)+
                    " tp="+DoubleToString(tpPoints,1)+
                    " net="+DoubleToString(netTpPoints,1));
         return;
        }
     }

   if(buySignal)
     {
      double sl = NormalizePriceToTick(ask - slDistance);
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
      double sl = NormalizePriceToTick(bid + slDistance);
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
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   if(trans.type!=TRADE_TRANSACTION_DEAL_ADD || trans.deal==0)
      return;

   if(trans.deal==gLastProcessedDeal)
      return;

   if(!HistoryDealSelect(trans.deal))
      return;

   string sym = HistoryDealGetString(trans.deal,DEAL_SYMBOL);
   long mg = HistoryDealGetInteger(trans.deal,DEAL_MAGIC);
   long entry = HistoryDealGetInteger(trans.deal,DEAL_ENTRY);
   if(sym!=gTradeSymbol || (ulong)mg!=InpMagic)
      return;
   if(entry!=DEAL_ENTRY_OUT && entry!=DEAL_ENTRY_OUT_BY && entry!=DEAL_ENTRY_INOUT)
      return;

   double profit = HistoryDealGetDouble(trans.deal,DEAL_PROFIT) +
                   HistoryDealGetDouble(trans.deal,DEAL_SWAP) +
                   HistoryDealGetDouble(trans.deal,DEAL_COMMISSION);

   if(profit>0.0)
      gWinStreak++;
   else
      gWinStreak = 0;

   if(gWinStreak>MathMax(0,InpMaxWinStreakSteps))
      gWinStreak = MathMax(0,InpMaxWinStreakSteps);

   gLastProcessedDeal = trans.deal;
   DebugPrint("Closed deal profit="+DoubleToString(profit,2)+
              " winStreak="+IntegerToString(gWinStreak));
  }

//+------------------------------------------------------------------+
bool ManageProfitRetraceExit()
  {
   if(!InpUseProfitRetraceExit)
      return(false);

   double point = SymbolInfoDouble(gTradeSymbol,SYMBOL_POINT);
   if(point<=0.0)
      return(false);

   double bid = SymbolInfoDouble(gTradeSymbol,SYMBOL_BID);
   double ask = SymbolInfoDouble(gTradeSymbol,SYMBOL_ASK);
   double startPoints = (double)MathMax(1,InpProfitRetraceStartPoints);
   double givebackPoints = (double)MathMax(1,InpProfitRetraceGivebackPoints);
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

      double currentPoints = 0.0;
      if(posType==POSITION_TYPE_BUY)
         currentPoints = (bid-openPrice)/point;
      else if(posType==POSITION_TYPE_SELL)
         currentPoints = (openPrice-ask)/point;
      else
         continue;

      UpsertTrackedBestPoints(ticket,currentPoints);
      int idx = FindTrackedTicketIndex(ticket);
      if(idx<0)
         continue;

      double bestPoints = gTrackBestPoints[idx];
      if(bestPoints < startPoints)
         continue;
      if(currentPoints <= 0.0)
         continue;

      if(currentPoints <= (bestPoints - givebackPoints))
        {
         if(trade.PositionClose(ticket))
           {
            DebugPrint("Profit retrace exit. Ticket="+(string)ticket+
                       " best="+DoubleToString(bestPoints,1)+
                       " current="+DoubleToString(currentPoints,1));
            closedAny = true;
           }
         else
           {
            Print("Profit retrace close failed. Ticket=",ticket,
                  " RetCode=",trade.ResultRetcode()," ",trade.ResultRetcodeDescription());
           }
        }
     }

   CleanupTrackedTickets();
   return(closedAny);
  }

//+------------------------------------------------------------------+
int FindTrackedTicketIndex(const ulong ticket)
  {
   int n = ArraySize(gTrackTickets);
   for(int i=0; i<n; i++)
      if(gTrackTickets[i]==ticket)
         return(i);
   return(-1);
  }

//+------------------------------------------------------------------+
void UpsertTrackedBestPoints(const ulong ticket,const double currentPoints)
  {
   int idx = FindTrackedTicketIndex(ticket);
   if(idx<0)
     {
      int n = ArraySize(gTrackTickets);
      ArrayResize(gTrackTickets,n+1);
      ArrayResize(gTrackBestPoints,n+1);
      gTrackTickets[n] = ticket;
      gTrackBestPoints[n] = currentPoints;
      return;
     }

   if(currentPoints > gTrackBestPoints[idx])
      gTrackBestPoints[idx] = currentPoints;
  }

//+------------------------------------------------------------------+
void CleanupTrackedTickets()
  {
   int n = ArraySize(gTrackTickets);
   for(int i=n-1; i>=0; i--)
     {
      ulong ticket = gTrackTickets[i];
      if(ticket==0 || !PositionSelectByTicket(ticket))
        {
         int last = ArraySize(gTrackTickets)-1;
         if(i!=last)
           {
            gTrackTickets[i] = gTrackTickets[last];
            gTrackBestPoints[i] = gTrackBestPoints[last];
           }
         ArrayResize(gTrackTickets,last);
         ArrayResize(gTrackBestPoints,last);
        }
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
double GetRoundTripCostPoints(const double lots)
  {
   double spreadPoints = (double)GetSpreadPoints();
   double slipPoints = (double)MathMax(0,InpEstimatedSlippagePointsRoundTrip);

   double tickSize  = SymbolInfoDouble(gTradeSymbol,SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(gTradeSymbol,SYMBOL_TRADE_TICK_VALUE);
   double point     = SymbolInfoDouble(gTradeSymbol,SYMBOL_POINT);
   if(tickSize<=0.0 || tickValue<=0.0 || point<=0.0)
      return(spreadPoints + slipPoints);

   double moneyPerPointPerLot = tickValue * (point / tickSize);
   if(moneyPerPointPerLot<=0.0 || lots<=0.0)
      return(spreadPoints + slipPoints);

   double roundCommission = MathMax(0.0,InpCommissionPerLotPerSideUSD) * 2.0 * lots;
   double commissionPoints = roundCommission / (moneyPerPointPerLot * lots);
   return(spreadPoints + slipPoints + commissionPoints);
  }

//+------------------------------------------------------------------+
bool IsEntryCostEfficient(const double lots,const double tpDistance,const double point,double &costPoints,double &tpPoints,double &netTpPoints)
  {
   costPoints = GetRoundTripCostPoints(lots);
   tpPoints = tpDistance / point;
   netTpPoints = tpPoints - costPoints;

   if(netTpPoints < (double)MathMax(1,InpMinNetTPAfterCostPoints))
      return(false);

   double ratio = 0.0;
   if(costPoints>0.0)
      ratio = tpPoints / costPoints;

   if(ratio < MathMax(0.1,InpMinTPtoCostRatio))
      return(false);

   return(true);
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
double CalculateLots(double slDistancePrice,const double riskPercent)
  {
   if(slDistancePrice<=0.0)
      return(0.0);

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   if(balance<=0.0 || equity<=0.0 || riskPercent<=0.0)
      return(0.0);

   // Use the smaller capital base for conservative risk sizing.
   double capital = MathMin(balance,equity);
   double riskMoney = capital * (riskPercent/100.0);
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
      // Optional hard fallback so EA can continue trading even when risk model returns too small lot.
      if(InpForceMinLotAlways && InpForceMinLot)
        {
         DebugPrint("Lot fallback: using min lot (risk model too small)");
         lots = minLot;
        }
      else if(InpForceMinLot && riskMoney >= (moneyPerLot * minLot))
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
   if(InpTrailingStopPoints<=0 && InpMinLockProfitPoints<=0)
      return;

   double point = SymbolInfoDouble(gTradeSymbol,SYMBOL_POINT);
   if(point<=0.0)
      return;
   int minStopPoints = GetMinStopPoints();
   int trailPoints = MathMax(MathMax(InpTrailingStopPoints,minStopPoints),200);
   int lockPoints = MathMax(0,InpMinLockProfitPoints);
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
         double moveProfit = (bid-openPrice);
         double newSL = currSL;

         if(lockPoints>0 && moveProfit >= ((double)lockPoints * point))
           {
            double lockSL = NormalizePriceToTick(openPrice + ((double)lockPoints * point));
            if(newSL==0.0 || lockSL>newSL)
               newSL = lockSL;
           }

         if(InpTrailingStopPoints>0 && moveProfit > ((double)trailPoints * point))
           {
            double trailSL = NormalizePriceToTick(bid - ((double)trailPoints * point));
            if(newSL==0.0 || trailSL>newSL)
               newSL = trailSL;
           }

         if(newSL<=0.0)
            continue;
         if((bid-newSL)<=minDistPrice)
            continue;
         if(currSL==0.0 || newSL>currSL)
            trade.PositionModify(gTradeSymbol,newSL,currTP);
        }
      else if(posType==POSITION_TYPE_SELL)
        {
         double moveProfit = (openPrice-ask);
         double newSL = currSL;

         if(lockPoints>0 && moveProfit >= ((double)lockPoints * point))
           {
            double lockSL = NormalizePriceToTick(openPrice - ((double)lockPoints * point));
            if(newSL==0.0 || lockSL<newSL)
               newSL = lockSL;
           }

         if(InpTrailingStopPoints>0 && moveProfit > ((double)trailPoints * point))
           {
            double trailSL = NormalizePriceToTick(ask + ((double)trailPoints * point));
            if(newSL==0.0 || trailSL<newSL)
               newSL = trailSL;
           }

         if(newSL<=0.0)
            continue;
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
