//+------------------------------------------------------------------+
//|                                                  AI_EA_YOU_2.mq5 |
//|    XAUUSD M1 Buy-Only Scalp with Trailing + SellLimit Recovery   |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"

#include <Trade/Trade.mqh>

CTrade trade;

input string InpSymbolKeyword            = "XAU";
input ENUM_TIMEFRAMES InpRequiredTF      = PERIOD_M1;
input long   InpMagicNumber              = 260307;

input double InpBaseLot                  = 0.01;
input double InpSellLimitLotMultiplier   = 2.0;
input int    InpSellLimitDistancePoints  = 200;

input int    InpTrailingStartPoints      = 120;
input int    InpTrailingDistancePoints   = 100;
input double InpCloseBasketProfitMoney   = 0.0;

input int    InpMaxSlippagePoints        = 30;
input string InpBuyComment               = "AI2_BUY";
input string InpSellLimitComment         = "AI2_SELLLIMIT";

//+------------------------------------------------------------------+
bool IsCorrectChart()
  {
   if(_Period != InpRequiredTF)
     {
      Comment("AI_EA_YOU_2: Use timeframe M1 only");
      return(false);
     }

   if(StringFind(_Symbol,InpSymbolKeyword) < 0)
     {
      Comment("AI_EA_YOU_2: Use XAU symbol only");
      return(false);
     }

   Comment("");
   return(true);
  }

//+------------------------------------------------------------------+
double NormalizeVolume(double volume)
  {
   double volMin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double volMax  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double volStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(volStep <= 0.0)
      volStep = volMin;
   if(volStep <= 0.0)
      volStep = 0.01;

   volume = MathMax(volMin, MathMin(volMax, volume));
   double steps = MathFloor(volume / volStep + 1e-8);
   return(steps * volStep);
  }

//+------------------------------------------------------------------+
bool GetOurBuyPosition(ulong &ticket,double &volume,double &openPrice,double &sl,double &profit)
  {
   int total = PositionsTotal();
   for(int i=0; i<total; i++)
     {
      ulong posTicket = PositionGetTicket(i);
      if(posTicket == 0)
         continue;

      if(!PositionSelectByTicket(posTicket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_BUY)
         continue;

      ticket    = posTicket;
      volume    = PositionGetDouble(POSITION_VOLUME);
      openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      sl        = PositionGetDouble(POSITION_SL);
      profit    = PositionGetDouble(POSITION_PROFIT);
      return(true);
     }

   return(false);
  }

//+------------------------------------------------------------------+
bool GetOurSellPosition(ulong &ticket,double &profit)
  {
   int total = PositionsTotal();
   for(int i=0; i<total; i++)
     {
      ulong posTicket = PositionGetTicket(i);
      if(posTicket == 0)
         continue;

      if(!PositionSelectByTicket(posTicket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_SELL)
         continue;

      ticket = posTicket;
      profit = PositionGetDouble(POSITION_PROFIT);
      return(true);
     }

   return(false);
  }

//+------------------------------------------------------------------+
bool GetOurSellLimitOrder(ulong &ticket,double &price,double &volume)
  {
   int total = OrdersTotal();
   for(int i=0; i<total; i++)
     {
      ulong ordTicket = OrderGetTicket(i);
      if(ordTicket == 0)
         continue;

      if(!OrderSelect(ordTicket))
         continue;

      if(OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;
      if((long)OrderGetInteger(ORDER_MAGIC) != InpMagicNumber)
         continue;
      if((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE) != ORDER_TYPE_SELL_LIMIT)
         continue;

      ticket = ordTicket;
      price  = OrderGetDouble(ORDER_PRICE_OPEN);
      volume = OrderGetDouble(ORDER_VOLUME_CURRENT);
      return(true);
     }

   return(false);
  }

//+------------------------------------------------------------------+
double GetBasketProfit()
  {
   double profit = 0.0;
   int total = PositionsTotal();

   for(int i=0; i<total; i++)
     {
      ulong posTicket = PositionGetTicket(i);
      if(posTicket == 0)
         continue;

      if(!PositionSelectByTicket(posTicket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      profit += PositionGetDouble(POSITION_PROFIT);
     }

   return(profit);
  }

//+------------------------------------------------------------------+
void DeleteAllSellLimitOrders()
  {
   int total = OrdersTotal();
   for(int i=total-1; i>=0; i--)
     {
      ulong ordTicket = OrderGetTicket(i);
      if(ordTicket == 0)
         continue;

      if(!OrderSelect(ordTicket))
         continue;

      if(OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;
      if((long)OrderGetInteger(ORDER_MAGIC) != InpMagicNumber)
         continue;
      if((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE) != ORDER_TYPE_SELL_LIMIT)
         continue;

      trade.OrderDelete(ordTicket);
     }
  }

//+------------------------------------------------------------------+
void CloseAllOurPositions()
  {
   int total = PositionsTotal();
   for(int i=total-1; i>=0; i--)
     {
      ulong posTicket = PositionGetTicket(i);
      if(posTicket == 0)
         continue;

      if(!PositionSelectByTicket(posTicket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      trade.PositionClose(posTicket);
     }
  }

//+------------------------------------------------------------------+
void ManageTrailingStop(const ulong buyTicket,const double openPrice,const double oldSl)
  {
   if(!PositionSelectByTicket(buyTicket))
      return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point <= 0.0)
      return;

   double profitPoints = (bid - openPrice) / point;
   if(profitPoints < InpTrailingStartPoints)
      return;

   double newSl = bid - InpTrailingDistancePoints * point;

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   newSl = NormalizeDouble(newSl, digits);

   if(oldSl > 0.0 && newSl <= oldSl)
      return;

   double tp = PositionGetDouble(POSITION_TP);
   trade.PositionModify(_Symbol, newSl, tp);
  }

//+------------------------------------------------------------------+
void PlaceOrUpdateSellLimit(const double buySl,const double buyVolume)
  {
   if(buySl <= 0.0)
      return;

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(point <= 0.0 || ask <= 0.0)
      return;

   double targetPrice = buySl + InpSellLimitDistancePoints * point;

   int stopLevelPoints = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDistance  = stopLevelPoints * point;

   if(targetPrice < ask + minDistance)
      targetPrice = ask + minDistance + point;

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   targetPrice = NormalizeDouble(targetPrice, digits);

   double sellLimitVol = NormalizeVolume(buyVolume * InpSellLimitLotMultiplier);

   ulong orderTicket = 0;
   double oldPrice = 0.0;
   double oldVol = 0.0;

   bool hasOrder = GetOurSellLimitOrder(orderTicket, oldPrice, oldVol);

   if(!hasOrder)
     {
      trade.SellLimit(sellLimitVol,
                      targetPrice,
                      _Symbol,
                      0.0,
                      0.0,
                      ORDER_TIME_GTC,
                      0,
                      InpSellLimitComment);
      return;
     }

   bool needPriceUpdate = (MathAbs(oldPrice - targetPrice) > (point * 2.0));
   bool needVolUpdate   = (MathAbs(oldVol - sellLimitVol) > 1e-8);

   if(!needPriceUpdate && !needVolUpdate)
      return;

   if(needVolUpdate)
     {
      trade.OrderDelete(orderTicket);
      trade.SellLimit(sellLimitVol,
                      targetPrice,
                      _Symbol,
                      0.0,
                      0.0,
                      ORDER_TIME_GTC,
                      0,
                      InpSellLimitComment);
      return;
     }

   trade.OrderModify(orderTicket, targetPrice, 0.0, 0.0, ORDER_TIME_GTC, 0, 0.0);
  }

//+------------------------------------------------------------------+
void OpenInitialBuyIfNeeded()
  {
   ulong buyTicket = 0;
   double buyVol = 0.0;
   double buyOpen = 0.0;
   double buySl = 0.0;
   double buyProfit = 0.0;

   ulong sellTicket = 0;
   double sellProfit = 0.0;

   if(GetOurBuyPosition(buyTicket,buyVol,buyOpen,buySl,buyProfit))
      return;

   if(GetOurSellPosition(sellTicket,sellProfit))
      return;

   ulong orderTicket = 0;
   double orderPrice = 0.0;
   double orderVol = 0.0;
   if(GetOurSellLimitOrder(orderTicket,orderPrice,orderVol))
      return;

   double lot = NormalizeVolume(InpBaseLot);
   trade.Buy(lot, _Symbol, 0.0, 0.0, 0.0, InpBuyComment);
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpMaxSlippagePoints);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   if(!IsCorrectChart())
      return;

   OpenInitialBuyIfNeeded();

   ulong buyTicket = 0;
   double buyVol = 0.0;
   double buyOpen = 0.0;
   double buySl = 0.0;
   double buyProfit = 0.0;

   ulong sellTicket = 0;
   double sellProfit = 0.0;

   bool hasBuy  = GetOurBuyPosition(buyTicket,buyVol,buyOpen,buySl,buyProfit);
   bool hasSell = GetOurSellPosition(sellTicket,sellProfit);

   if(hasBuy)
     {
      ManageTrailingStop(buyTicket,buyOpen,buySl);

      // Refresh buy SL after possible trailing update.
      if(PositionSelectByTicket(buyTicket))
         buySl = PositionGetDouble(POSITION_SL);

      if(!hasSell)
         PlaceOrUpdateSellLimit(buySl,buyVol);
     }

   if(hasSell)
      DeleteAllSellLimitOrders();

   if(hasBuy && hasSell)
     {
      double basketProfit = GetBasketProfit();
      if(basketProfit >= InpCloseBasketProfitMoney)
        {
         CloseAllOurPositions();
         DeleteAllSellLimitOrders();
        }
     }
  }
//+------------------------------------------------------------------+
