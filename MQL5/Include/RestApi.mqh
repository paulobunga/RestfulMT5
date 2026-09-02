#property version   "1.00"

#include <Json.mqh>
#include <Trade/Trade.mqh>
#include <Strings/String.mqh>
#include <MovingAverages.mqh>

#import "mt5-rest.dll"
   int Init( const uchar &host[], int port, int command_wait_timeout, const uchar&path[], const uchar &url[]);
   int GetCommand(uchar &data[]);
   int SetCallback(const uchar &url[], const uchar &format[]);
   int SetCommandResponse(const uchar &command[], const uchar &response[]);
   int RaiseEvent(const uchar &data[]);
   int SetAuthToken(const uchar &token[]);
   void Deinit();
#import

class CRestApi
  {

public:
                     CRestApi(void);
                    ~CRestApi(void);
   static string    GetErrorID(int error);
   static string    GetRetcodeID(int retcode);
   static int       Pub(string message) {
      uchar d[];
      StringToCharArray(message,d);
      
      return RaiseEvent( d );   
   };
   static int       SetCallback(string url, string format) {
      uchar u[], f[];
      StringToCharArray(url,u);
      StringToCharArray(format,f);

      return ::SetCallback( u, f );
   };   
                    
   //---
   bool              Init(string _host, int _port, int commandWaitTimeout, string _url_swagger);
   bool              SetAuth(string token);
   void              Deinit(void);
   void              Processing(void);
   void              OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result);
   
private:
   string notImpemented(string command);
   string getAccountInfo();
   string getSymbolInfo(string name);
   string getPositions();
   string getPosition(ulong ticket);   
   string getBalanceInfo();
   string getOrders();
   string getOrdersHistory(CJAVal &dataObject);
   string getOrder(ulong ticket);
   string getOrderHistory(ulong ticket);
   string getTransactions(CJAVal &dataObject);
   string getTransaction(ulong ticket);
   string tradingModule(CJAVal &dataObject);
   string getCandleData(CJAVal &dataObject);
   string orderDoneOrError(bool error, string funcName, CTrade &trade, string pSymbol="", string pType="");
   string actionDoneOrError(int lastError, string funcName);
   string fromDateTime(datetime param);
   datetime parseFromParam(string s);
   datetime parseToParam(string s);
   string   dealReasonString(int reason);
   string   dealEntryString(int entry);
   string   orderReasonString(int reason);
   ENUM_TIMEFRAMES StringToTimeframe(string tf);
   //--- new methods for full MT5 coverage
   string getAccount();
   string getSymbols();
   string getSymbolInfoFull(string name);
   string getTick(string symbol);
   string getPositionsPnl();
   string getMargin(string symbol);
   string getAccountHistory(CJAVal &dataObject);
   string tradeCloseAll();
   string tradeCloseSymbol(string symbol);
   string tradeBatch(CJAVal &dataObject);
private:
   bool debug;
};

CRestApi::CRestApi(void) {
   debug = true;
}
//+------------------------------------------------------------------+
//| Destructor                                                       |
//+------------------------------------------------------------------+
CRestApi::~CRestApi(void)
  {
  }
//+------------------------------------------------------------------+
//| Method Init.                                                     |
//+------------------------------------------------------------------+
bool CRestApi::Init(string _host, int _port, int _commandWaitTimeout, string _url_swagger) {
   uchar __host[], _path[], _url[];
   StringToCharArray(_host, __host);
   StringToCharArray(_url_swagger, _url);
   StringToCharArray(TerminalInfoString(TERMINAL_DATA_PATH) + "\\MQL5\\Libraries\\", _path);

   ::Init(__host, _port, _commandWaitTimeout, _path, _url);
   
   if(debug) Print("started");
   
   ChartRedraw();
   return(true);   
}

bool CRestApi::SetAuth(string token) {
   uchar d[];
   StringToCharArray(token,d);
   int ret = SetAuthToken( d );
   
   return true;
}
//+------------------------------------------------------------------+
//| Method Deinit.                                                   |
//+------------------------------------------------------------------+
void CRestApi::Deinit(void) {
   ::Deinit();
}

void CRestApi::Processing(void) {
  
  uchar _command[8048];
  uchar _response[];
  string command = "";
  string response = "";
  
   int r = 0;
   r = GetCommand( _command );
   
   if(r == 1) {
      command = CharArrayToString( _command );
      Print("command: " + command);
      
      CJAVal jCommand;
      CJAVal *id;
      
      jCommand.Deserialize( command );
      
      string action = jCommand["command"].ToStr();
      
      if(action == "inited") {
         Print("Listening on: " + jCommand["options"].ToStr());
         Comment("Open " + jCommand["options"].ToStr() + " for docs");
         
         return;
      }      
      
      if(action == "failed") {
         Print("Failed to start, error: " + jCommand["options"].ToStr());
         Comment("Failed to start server: " + jCommand["options"].ToStr());
         
         return;
      }            
      
      if(action == "info") {
         response = getAccountInfo();
      }
      
      if(action == "balance") {
         response = getBalanceInfo();
      }
      
      if(action == "symbols") {
         id = jCommand.HasKey("id", jtSTR);
         
         if(id != NULL)      
            response = getSymbolInfoFull(id.ToStr());
         else
            response = getSymbols();
      }      
      
      if(action == "orders") {
      
         id = jCommand.HasKey("id");
         
         if(id != NULL)      
            response = getOrder(id.ToInt());
         else
            response = getOrders();                 
      }      
      
      if(action == "history") {
         id = jCommand.HasKey("id");
         Print(id);
         
if(id != NULL)      
             response = getOrderHistory(id.ToInt());
          else
             response = getOrdersHistory(jCommand);
      }            
      
      if(action == "positions") {
         id = jCommand.HasKey("id");
         
         if(id != NULL)      
            response = getPosition(id.ToInt());
         else
            response = getPositions();
      }                  
      
      if(action == "deals") {
      
         id = jCommand.HasKey("id");
         
         if(id != NULL)      
            response = getTransaction(id.ToInt());
         else
            response = getTransactions(jCommand);
      }                        
      
      if(action == "trade") {
         response = tradingModule(jCommand);
      }

      if(action == "candles") {
         response = getCandleData(jCommand);
      }

      //--- new actions for full MT5 coverage

      if(action == "account") {
         response = getAccount();
      }

      if(action == "tick") {
         id = jCommand.HasKey("id", jtSTR);
         if(id != NULL)
            response = getTick(id.ToStr());
      }

      if(action == "positions_pnl") {
         response = getPositionsPnl();
      }

      if(action == "margin") {
         id = jCommand.HasKey("id", jtSTR);
         if(id != NULL)
            response = getMargin(id.ToStr());
      }

      if(action == "account_history") {
         response = getAccountHistory(jCommand);
      }

      if(action == "trade_close_all") {
         response = tradeCloseAll();
      }

      if(action == "trade_close_symbol") {
         id = jCommand.HasKey("symbol", jtSTR);
         if(id != NULL)
            response = tradeCloseSymbol(id.ToStr());
      }

      if(action == "trade_batch") {
         response = tradeBatch(jCommand);
      }

      //--- DELETE /orders/{id}
      if(action == "order_delete") {
         CJAVal *oid = jCommand.HasKey("id", jtSTR);
         if(oid != NULL) {
            int ticket = (int)StringToInteger(oid.ToStr());
            CTrade trade;
            if(trade.OrderDelete(ticket))
               response = orderDoneOrError(false, __FUNCTION__, trade);
            else
               response = orderDoneOrError(true, __FUNCTION__, trade);
         }
      }

      //--- DELETE /positions/{id}
      if(action == "position_delete") {
         CJAVal *oid = jCommand.HasKey("id", jtSTR);
         if(oid != NULL) {
            int ticket = (int)StringToInteger(oid.ToStr());
            CTrade trade;
            if(trade.PositionClose(ticket))
               response = orderDoneOrError(false, __FUNCTION__, trade);
            else
               response = orderDoneOrError(true, __FUNCTION__, trade);
         }
      }

      //--- PUT/PATCH /orders/{id}
      if(action == "order_modify") {
         CJAVal *oid = jCommand.HasKey("id", jtSTR);
         if(oid != NULL) {
            int ticket = (int)StringToInteger(oid.ToStr());
            CTrade trade;
            double   price=0, SL=0, TP=0;
            datetime expiration=TimeTradeServer()+PeriodSeconds(PERIOD_D1);

            CJAVal *p = jCommand.HasKey("price", jtDOUBLE);
            if(p != NULL) price = NormalizeDouble(p.ToDbl(), _Digits);

            CJAVal *s = jCommand.HasKey("stoploss", jtDOUBLE);
            if(s != NULL) SL = s.ToDbl();

            CJAVal *t = jCommand.HasKey("takeprofit", jtDOUBLE);
            if(t != NULL) TP = t.ToDbl();

            if(trade.OrderModify(ticket, price, SL, TP, ORDER_TIME_GTC, expiration))
               response = orderDoneOrError(false, __FUNCTION__, trade);
            else
               response = orderDoneOrError(true, __FUNCTION__, trade);
         }
      }

      //--- PUT/PATCH /positions/{id}
      if(action == "position_modify") {
         CJAVal *oid = jCommand.HasKey("id", jtSTR);
         if(oid != NULL) {
            int ticket = (int)StringToInteger(oid.ToStr());
            CTrade trade;
            double SL=0, TP=0;

            CJAVal *s = jCommand.HasKey("stoploss", jtDOUBLE);
            if(s != NULL) SL = s.ToDbl();

            CJAVal *t = jCommand.HasKey("takeprofit", jtDOUBLE);
            if(t != NULL) TP = t.ToDbl();

            if(trade.PositionModify(ticket, SL, TP))
               response = orderDoneOrError(false, __FUNCTION__, trade);
            else
               response = orderDoneOrError(true, __FUNCTION__, trade);
         }
      }

      if(StringLen(response) < 1) {
         response = notImpemented(action);
      } 
      
      StringToCharArray(response,_response);
      SetCommandResponse( _command, _response );
   }
}

string CRestApi::notImpemented(string command) {
   CJAVal info;
   
   info["error"] = "Not implemented";
   info["command"] = command;
   
   string t = info.Serialize();
   
   if(debug) Print(t);
   
   return t;
}

string CRestApi::getSymbolInfo(string symbol) {
   CJAVal info;
   MqlTick last_tick;

   if(SymbolInfoTick(symbol,last_tick)) {
      info["ask"] = last_tick.ask;
      info["bid"] = last_tick.bid;
      info["time"] = fromDateTime(last_tick.time);
      info["tick_size"] = SymbolInfoDouble( symbol, SYMBOL_TRADE_TICK_SIZE );
      info["tick_value"] = SymbolInfoDouble( symbol, SYMBOL_TRADE_TICK_VALUE );
      info["contract_size"] = SymbolInfoDouble( symbol, SYMBOL_TRADE_CONTRACT_SIZE );
      info["min_volume"] = SymbolInfoDouble( symbol, SYMBOL_VOLUME_MIN );
      info["max_volume"] = SymbolInfoDouble( symbol, SYMBOL_VOLUME_MAX );
      info["volume_step"] = SymbolInfoDouble( symbol, SYMBOL_VOLUME_STEP );
      
      string t=info.Serialize();
      if(debug) Print(t);
      return t;      
   }
   
   return actionDoneOrError(ERR_MARKET_UNKNOWN_SYMBOL, __FUNCTION__);
}

string CRestApi::getAccountInfo() {  
   CJAVal info;
   
   info["broker"] = AccountInfoString(ACCOUNT_COMPANY);
   info["currency"] = AccountInfoString(ACCOUNT_CURRENCY);
   info["server"] = AccountInfoString(ACCOUNT_SERVER); 
   info["balance"] = AccountInfoDouble(ACCOUNT_BALANCE);
   info["equity"] = AccountInfoDouble(ACCOUNT_EQUITY);
   info["margin"] = AccountInfoDouble(ACCOUNT_MARGIN);
   info["margin_free"] = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   info["leverage"] = AccountInfoInteger(ACCOUNT_LEVERAGE);
   info["margin_level"] = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
   info["positions_total"] = PositionsTotal();
   if (HistorySelect(0,TimeCurrent())) {
      info["orders_total"] = OrdersTotal();   
   } else {
      info["orders_total"] = 0;
   }
      
   string t=info.Serialize();
   if(debug) Print(t);
   return t;
}

//+------------------------------------------------------------------+
//| Balance information                                              |
//+------------------------------------------------------------------+
string CRestApi::getBalanceInfo() {  
   CJAVal info;
   info["balance"] = AccountInfoDouble(ACCOUNT_BALANCE);
   info["equity"] = AccountInfoDouble(ACCOUNT_EQUITY);
   info["margin"] = AccountInfoDouble(ACCOUNT_MARGIN);
   info["margin_free"] = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   
   info["positions_total"] = PositionsTotal();
   if (HistorySelect(0,TimeCurrent())) {
      info["deal_total"] = HistoryDealsTotal();
      info["orders_total"] = OrdersTotal();   
   } else {
      info["deal_total"] = 0;
      info["orders_total"] = 0;
   }
   
   string t = info.Serialize();
   if(debug) Print(t);   
   
   return t;
}

//+------------------------------------------------------------------+
//| Fetch positions information                                      |
//+------------------------------------------------------------------+
string CRestApi::getPositions() {
      CPositionInfo myposition;
      CJAVal data, position;
   
      // Get positions  
      int positionsTotal=PositionsTotal();
      // Create empty array if no positions
      if(!positionsTotal) data.Add(position);
      // Go through positions in a loop
      for(int i=0;i<positionsTotal;i++)
        {
         ResetLastError();
         
         if(myposition.SelectByIndex(i))
            {
              position["id"]=PositionGetInteger(POSITION_IDENTIFIER);
              position["magic"]=PositionGetInteger(POSITION_MAGIC);
              position["symbol"]=PositionGetString(POSITION_SYMBOL);
              position["type"]=EnumToString(ENUM_POSITION_TYPE(PositionGetInteger(POSITION_TYPE)));
              position["time_setup"] = fromDateTime(PositionGetInteger(POSITION_TIME));
              position["open"]=PositionGetDouble(POSITION_PRICE_OPEN);
              position["stoploss"]=PositionGetDouble(POSITION_SL);
              position["takeprofit"]=PositionGetDouble(POSITION_TP);
              position["volume"]=PositionGetDouble(POSITION_VOLUME);
              position["price_current"]=PositionGetDouble(POSITION_PRICE_CURRENT);
            
              data.Add(position);
            }
          // Error handling    
          else actionDoneOrError(ERR_TRADE_POSITION_NOT_FOUND, __FUNCTION__);
         }
      string t=data.Serialize();
      if(debug) Print(t);
      
      return t;
}

//+------------------------------------------------------------------+
//| Fetch transactions information                                   |
//+------------------------------------------------------------------+
string CRestApi::getTransactions(CJAVal &dataObject) {
      ResetLastError();

      string   symbolFilter   = dataObject["symbol"].ToStr();
      ulong    positionId     = (ulong)dataObject["position_id"].ToInt();
      int      offset         = (int)MathMax(0, dataObject["offset"].ToInt());
      int      limit          = (int)dataObject["limit"].ToInt();
      if(limit <= 0) limit = 100;
      if(limit > 500) limit = 500;
      datetime fromD = parseFromParam(dataObject["from"].ToStr());
      datetime toD   = parseToParam(dataObject["to"].ToStr());

      CJAVal data, deal;
      ulong  collected[];
      int    collectedCount = 0;

      if(HistorySelect(fromD, toD)) {
         int dealsTotal = HistoryDealsTotal();
         ArrayResize(collected, dealsTotal > 0 ? dealsTotal : 1);

         for(int i = dealsTotal-1; i >= 0; i--) {      // newest first
            ulong ticket = HistoryDealGetTicket(i);
            if(ticket == 0) continue;
            bool matchPos  = (positionId == 0) || ((ulong)HistoryDealGetInteger(ticket, DEAL_POSITION_ID) == positionId);
            bool matchSym  = (symbolFilter == "") || (HistoryDealGetString(ticket, DEAL_SYMBOL) == symbolFilter);
            if(matchPos && matchSym)
               collected[collectedCount++] = ticket;
         }
      }

      int total = collectedCount;
      int start = MathMin(offset, total);
      int end   = MathMin(offset + limit, total);

      for(int k = start; k < end; k++) {
         ulong ticket = collected[k];
         deal["id"]          = (int)ticket;
         deal["price"]       = HistoryDealGetDouble(ticket, DEAL_PRICE);
         deal["commission"]  = HistoryDealGetDouble(ticket, DEAL_COMMISSION);
         deal["swap"]        = HistoryDealGetDouble(ticket, DEAL_SWAP);
         deal["profit"]      = HistoryDealGetDouble(ticket, DEAL_PROFIT);
         deal["volume"]      = HistoryDealGetDouble(ticket, DEAL_VOLUME);
         deal["time"]        = fromDateTime(HistoryDealGetInteger(ticket, DEAL_TIME));
         deal["symbol"]      = HistoryDealGetString(ticket, DEAL_SYMBOL);
         deal["type"]        = EnumToString((ENUM_DEAL_TYPE)HistoryDealGetInteger(ticket, DEAL_TYPE));
         deal["position_id"] = HistoryDealGetInteger(ticket, DEAL_POSITION_ID);
         deal["order_id"]    = HistoryDealGetInteger(ticket, DEAL_ORDER);
         deal["entry"]       = dealEntryString((int)HistoryDealGetInteger(ticket, DEAL_ENTRY));
         deal["reason"]      = dealReasonString((int)HistoryDealGetInteger(ticket, DEAL_REASON));
         deal["comment"]     = HistoryDealGetString(ticket, DEAL_COMMENT);
         data.Add(deal);
      }

      CJAVal out;
      out["deals"].Set(data);
      out["total"] = (ulong)total;

      string t = out.Serialize();
      if(debug) {Print(t);}

      return t;
}

//+------------------------------------------------------------------+
//| Fetch orders information                                         |
//+------------------------------------------------------------------+
string CRestApi::getOrders() {
      ResetLastError();
      
      COrderInfo myorder;
      CJAVal data, order;
      
      // Get orders
      if (HistorySelect(0,TimeCurrent()))   
         {    
            int ordersTotal = OrdersTotal();
            // Create empty array if no orders
            if(!ordersTotal) {
              data.Add(order);
            }
            
            for(int i=0;i<ordersTotal;i++)
             {
   
               if (myorder.Select(OrderGetTicket(i))) 
                {   
                  order["id"]=(int) myorder.Ticket();
                  order["magic"]=OrderGetInteger(ORDER_MAGIC); 
                  order["symbol"]=OrderGetString(ORDER_SYMBOL);
                  order["type"]=EnumToString(ENUM_ORDER_TYPE(OrderGetInteger(ORDER_TYPE)));
                  order["time_setup"]=fromDateTime(OrderGetInteger(ORDER_TIME_SETUP));
                  order["open"]=OrderGetDouble(ORDER_PRICE_OPEN);
                  order["stoploss"]=OrderGetDouble(ORDER_SL);
                  order["takeprofit"]=OrderGetDouble(ORDER_TP);
                  order["volume"]=OrderGetDouble(ORDER_VOLUME_INITIAL);
                  
                  data.Add(order);
                } 
             }
         }
         
       string t=data.Serialize();
       if(debug) {Print(t);}
       
       return t;
 }
 
 
string CRestApi::getOrdersHistory(CJAVal &dataObject) {
      ResetLastError();

      string   symbolFilter = dataObject["symbol"].ToStr();
      ulong    positionId   = (ulong)dataObject["position_id"].ToInt();
      int      offset       = (int)MathMax(0, dataObject["offset"].ToInt());
      int      limit        = (int)dataObject["limit"].ToInt();
      if(limit <= 0) limit = 100;
      if(limit > 500) limit = 500;
      datetime fromD = parseFromParam(dataObject["from"].ToStr());
      datetime toD   = parseToParam(dataObject["to"].ToStr());

      CJAVal data, order;
      ulong  collected[];
      int    collectedCount = 0;

      if(HistorySelect(fromD, toD)) {
         int ordersTotal = HistoryOrdersTotal();
         ArrayResize(collected, ordersTotal > 0 ? ordersTotal : 1);

         for(int i = ordersTotal-1; i >= 0; i--) {    // newest first
            ulong ticket = HistoryOrderGetTicket(i);
            if(ticket == 0) continue;
            bool matchPos = (positionId == 0) || ((ulong)HistoryOrderGetInteger(ticket, ORDER_POSITION_ID) == positionId);
            bool matchSym = (symbolFilter == "") || (HistoryOrderGetString(ticket, ORDER_SYMBOL) == symbolFilter);
            if(matchPos && matchSym)
               collected[collectedCount++] = ticket;
         }
      }

      int total = collectedCount;
      int start = MathMin(offset, total);
      int end   = MathMin(offset + limit, total);

      for(int k = start; k < end; k++) {
         ulong ticket = collected[k];
         int state   = (int)HistoryOrderGetInteger(ticket, ORDER_STATE);
         double fill = (state == (int)ORDER_STATE_FILLED)
                          ? HistoryOrderGetDouble(ticket, ORDER_PRICE_CURRENT)
                          : 0;

         order["id"]          = (int)ticket;
         order["open"]        = HistoryOrderGetDouble(ticket, ORDER_PRICE_OPEN);
         order["fill"]        = fill;
         order["symbol"]      = HistoryOrderGetString(ticket, ORDER_SYMBOL);
         order["state"]       = EnumToString((ENUM_ORDER_STATE)state);
         order["magic"]       = HistoryOrderGetInteger(ticket, ORDER_MAGIC);
         order["type"]        = EnumToString((ENUM_ORDER_TYPE)HistoryOrderGetInteger(ticket, ORDER_TYPE));
         order["type_filling"]= EnumToString((ENUM_ORDER_TYPE_FILLING)HistoryOrderGetInteger(ticket, ORDER_TYPE_FILLING));
         order["time_setup"]  = fromDateTime(HistoryOrderGetInteger(ticket, ORDER_TIME_SETUP));
         order["time_done"]   = fromDateTime(HistoryOrderGetInteger(ticket, ORDER_TIME_DONE));
         order["time_expiration"] = fromDateTime(HistoryOrderGetInteger(ticket, ORDER_TIME_EXPIRATION));
         order["stoploss"]    = HistoryOrderGetDouble(ticket, ORDER_SL);
         order["takeprofit"]  = HistoryOrderGetDouble(ticket, ORDER_TP);
         order["volume"]      = HistoryOrderGetDouble(ticket, ORDER_VOLUME_INITIAL);
         order["position_id"] = HistoryOrderGetInteger(ticket, ORDER_POSITION_ID);
         order["reason"]      = orderReasonString((int)HistoryOrderGetInteger(ticket, ORDER_REASON));
         order["comment"]     = HistoryOrderGetString(ticket, ORDER_COMMENT);
         data.Add(order);
      }

      CJAVal out;
      out["orders"].Set(data);
      out["total"] = (ulong)total;

      string t = out.Serialize();
      if(debug) {Print(t);}

      return t;
}


//+------------------------------------------------------------------+
//| Fetch order information                                          |
//+------------------------------------------------------------------+
string CRestApi::getOrder(ulong ticket) {
      ResetLastError();
      
      COrderInfo myorder;
      CJAVal data, order;
      
      if (myorder.Select(ticket)) {   
         order["id"]=(int)myorder.Ticket();
         order["magic"]=OrderGetInteger(ORDER_MAGIC); 
         order["symbol"]=OrderGetString(ORDER_SYMBOL);
         order["type"]=EnumToString(ENUM_ORDER_TYPE(OrderGetInteger(ORDER_TYPE)));
         order["time_setup"]=fromDateTime(OrderGetInteger(ORDER_TIME_SETUP));
         order["open"]=OrderGetDouble(ORDER_PRICE_OPEN);
         order["stoploss"]=OrderGetDouble(ORDER_SL);
         order["takeprofit"]=OrderGetDouble(ORDER_TP);
         order["volume"]=OrderGetDouble(ORDER_VOLUME_INITIAL);
         
         return order.Serialize();
      }            
      
      return actionDoneOrError(ERR_TRADE_ORDER_NOT_FOUND, __FUNCTION__);
}

string CRestApi::getOrderHistory(ulong ticket) {
      ResetLastError();
      
      COrderInfo myorder;
      CJAVal data, order;
      
      HistorySelect(0,TimeCurrent());
      
      if (HistoryOrderSelect( ticket )) {
         order["id"]=(int)ticket;
         order["open"]=HistoryOrderGetDouble(ticket,ORDER_PRICE_OPEN);         
         order["symbol"]=HistoryOrderGetString(ticket,ORDER_SYMBOL);
         
         order["state"]=EnumToString(ENUM_ORDER_STATE(HistoryOrderGetInteger(ticket, ORDER_STATE)));
         order["magic"]=HistoryOrderGetInteger(ticket, ORDER_MAGIC); 
         order["type"]=EnumToString(ENUM_ORDER_TYPE(HistoryOrderGetInteger(ticket, ORDER_TYPE)));
         order["time_setup"]=fromDateTime(HistoryOrderGetInteger(ticket, ORDER_TIME_SETUP));
         order["time_done"]=fromDateTime(HistoryOrderGetInteger(ticket, ORDER_TIME_DONE));
         
         order["stoploss"]=HistoryOrderGetDouble(ticket, ORDER_SL);
         order["takeprofit"]=HistoryOrderGetDouble(ticket, ORDER_TP);
         order["volume"]=HistoryOrderGetDouble(ticket, ORDER_VOLUME_INITIAL);
         order["position_id"]=HistoryOrderGetInteger(ticket, ORDER_POSITION_ID);
         
         return order.Serialize();
      }            
      
      return actionDoneOrError(ERR_TRADE_ORDER_NOT_FOUND, __FUNCTION__);
}

string CRestApi::getTransaction(ulong ticket) {
      ResetLastError();
      
      CJAVal deal;
      
      if (HistorySelect(0,TimeCurrent()) && HistoryDealSelect(ticket)) {   
         deal["id"] = (int)ticket;
         deal["price"] = HistoryDealGetDouble(ticket,DEAL_PRICE);
         deal["commission"] = HistoryDealGetDouble(ticket,DEAL_COMMISSION);
         deal["time"]= fromDateTime(HistoryDealGetInteger(ticket,DEAL_TIME));
         deal["symbol"]=HistoryDealGetString(ticket,DEAL_SYMBOL);
         deal["type"]=EnumToString(ENUM_DEAL_TYPE(HistoryDealGetInteger(ticket,DEAL_TYPE)));                  
         deal["profit"] = HistoryDealGetDouble(ticket,DEAL_PROFIT);       
         deal["volume"] = HistoryDealGetDouble(ticket,DEAL_VOLUME);
         deal["position_id"] = HistoryDealGetInteger(ticket,DEAL_POSITION_ID);
         deal["order_id"] = HistoryDealGetInteger(ticket,DEAL_ORDER);
         
         return deal.Serialize();
      }      
      

      return actionDoneOrError(ERR_TRADE_DEAL_NOT_FOUND, __FUNCTION__);
 }

string CRestApi::getPosition(ulong ticket) {
   ResetLastError();
   
   CJAVal position;
   CPositionInfo myposition;
   
   ResetLastError();
   
   if(myposition.SelectByTicket(ticket)) {
        position["id"]=PositionGetInteger(POSITION_IDENTIFIER);
        position["magic"]=PositionGetInteger(POSITION_MAGIC);
        position["symbol"]=PositionGetString(POSITION_SYMBOL);
        position["type"]=EnumToString(ENUM_POSITION_TYPE(PositionGetInteger(POSITION_TYPE)));
        position["time_setup"] = fromDateTime(PositionGetInteger(POSITION_TIME));
        position["open"]=PositionGetDouble(POSITION_PRICE_OPEN);
        position["stoploss"]=PositionGetDouble(POSITION_SL);
        position["takeprofit"]=PositionGetDouble(POSITION_TP);
        position["volume"]=PositionGetDouble(POSITION_VOLUME);
        position["price_current"]=PositionGetDouble(POSITION_PRICE_CURRENT);
        
        return position.Serialize();
    }
    
    return actionDoneOrError(ERR_TRADE_POSITION_NOT_FOUND, __FUNCTION__);
 }

//+------------------------------------------------------------------+
//| Trading module                                                   |
//+------------------------------------------------------------------+
string CRestApi::tradingModule(CJAVal &dataObject) {
      ResetLastError();
      CTrade trade;
      
      string   actionType = dataObject["actionType"].ToStr();
      string   symbol=dataObject["symbol"].ToStr();
      // Check if symbol the same
      if(!(symbol==_Symbol)) return actionDoneOrError(ERR_MARKET_UNKNOWN_SYMBOL, __FUNCTION__);
      
      int      idNimber=(int)dataObject["id"].ToInt();
      double   volume=dataObject["volume"].ToDbl();
      double   SL=dataObject["stoploss"].ToDbl();
      double   TP=dataObject["takeprofit"].ToDbl();
      double   price=NormalizeDouble(dataObject["price"].ToDbl(),_Digits);
      datetime expiration=TimeTradeServer()+PeriodSeconds(PERIOD_D1);
      double   deviation=dataObject["deviation"].ToDbl();  
      string   comment=dataObject["comment"].ToStr();
      
      // Market orders
      if(actionType=="ORDER_TYPE_BUY" || actionType=="ORDER_TYPE_SELL")
         {  
            ENUM_ORDER_TYPE orderType;
            
            if( actionType=="ORDER_TYPE_BUY" )
               orderType = ORDER_TYPE_BUY;
            else
              orderType = ORDER_TYPE_SELL;
               
            price = SymbolInfoDouble(symbol,SYMBOL_ASK);                                        
            if(orderType==ORDER_TYPE_SELL) price=SymbolInfoDouble(symbol,SYMBOL_BID);
            
            if(trade.PositionOpen(symbol,orderType,volume,price,SL,TP,comment)) {
               return orderDoneOrError(false, __FUNCTION__, trade, symbol, actionType);
             }
           }
      
      // Pending orders
      else if(actionType=="ORDER_TYPE_BUY_LIMIT" || actionType=="ORDER_TYPE_SELL_LIMIT" || actionType=="ORDER_TYPE_BUY_STOP" || actionType=="ORDER_TYPE_SELL_STOP")
         {  
            if(actionType=="ORDER_TYPE_BUY_LIMIT") 
               {
                  if(trade.BuyLimit(volume,price,symbol,SL,TP,ORDER_TIME_GTC,expiration,comment))
                     {return orderDoneOrError(false, __FUNCTION__, trade, symbol, actionType);}
               }
            else if(actionType=="ORDER_TYPE_SELL_LIMIT")
               {
                  if(trade.SellLimit(volume,price,symbol,SL,TP,ORDER_TIME_GTC,expiration,comment))
                     {return orderDoneOrError(false, __FUNCTION__, trade, symbol, actionType);}
               }
            else if(actionType=="ORDER_TYPE_BUY_STOP")
               {
                  if(trade.BuyStop(volume,price,symbol,SL,TP,ORDER_TIME_GTC,expiration,comment))
                     {return orderDoneOrError(false, __FUNCTION__, trade, symbol, actionType);}
               }
            else if (actionType=="ORDER_TYPE_SELL_STOP")
               {
                  if(trade.SellStop(volume,price,symbol,SL,TP,ORDER_TIME_GTC,expiration,comment))
                     {return orderDoneOrError(false, __FUNCTION__, trade, symbol, actionType);}
               }
          }
      // Position modify    
      else if(actionType=="POSITION_MODIFY")
         {
            if(trade.PositionModify(idNimber,SL,TP)) 
               {return orderDoneOrError(false, __FUNCTION__, trade, symbol, "");}
         }
      // Position close partial   
      else if(actionType=="POSITION_PARTIAL")
         {
            if(trade.PositionClosePartial(idNimber,volume)) 
               {return orderDoneOrError(false, __FUNCTION__, trade, symbol, "");}
         }
      // Position close by id       
      else if(actionType=="POSITION_CLOSE_ID")
         {
            if(trade.PositionClose(idNimber)) 
               {return orderDoneOrError(false, __FUNCTION__, trade, symbol, "");}
         }
      // Position close by symbol
      else if(actionType=="POSITION_CLOSE_SYMBOL")
         {
            if(trade.PositionClose(symbol)) 
               {return orderDoneOrError(false, __FUNCTION__, trade, symbol, "");}
         }
      // Modify pending order
      else if(actionType=="ORDER_MODIFY")
         {  
            if(trade.OrderModify(idNimber,price,SL,TP,ORDER_TIME_GTC,expiration))
               {return orderDoneOrError(false, __FUNCTION__, trade, symbol, "");}
        }
      // Cancel pending order  
      else if(actionType=="ORDER_CANCEL")
         {
            if(trade.OrderDelete(idNimber))
               {return orderDoneOrError(false, __FUNCTION__, trade, symbol, "");}
         }
      // Action type dosen't exist
      else return actionDoneOrError(65538, __FUNCTION__);
      
      // Order is not compleated
      return orderDoneOrError(true, __FUNCTION__, trade);
   }

//+------------------------------------------------------------------+ 
//| TradeTransaction function                                        | 
//+------------------------------------------------------------------+ 
void CRestApi::OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result) {
      ENUM_TRADE_TRANSACTION_TYPE  trans_type=trans.type;
      switch(trans.type)
        {
         case  TRADE_TRANSACTION_REQUEST:
            {
               CJAVal data, req, res;
               
               req["action"]=EnumToString(request.action);
               req["order_id"]=(int) request.order;
               req["symbol"]=(string) request.symbol;
               req["volume"]=(double) request.volume;
               req["price"]=(double) request.price;
               req["stoplimit"]=(double) request.stoplimit;
               req["sl"]=(double) request.sl;
               req["tp"]=(double) request.tp;
               req["deviation"]=(int) request.deviation;
               req["type"]=EnumToString(request.type);
               req["type_filling"]=EnumToString(request.type_filling);
               req["type_time"]=EnumToString(request.type_time);
               req["expiration"]=(int) request.expiration;
               req["comment"]=(string) request.comment;
               req["position"]=(int) request.position;
               req["position_by"]=(int) request.position_by;
               
               res["retcode"]=(int) result.retcode;
               res["result"]=(string) CRestApi::GetRetcodeID(result.retcode);
               res["deal"]=(int) result.order;
               res["order_id"]=(int) result.order;
               res["volume"]=(double) result.volume;
               res["price"]=(double) result.price;
               res["comment"]=(string) result.comment;
               res["request_id"]=(int) result.request_id;
               res["retcode_external"]=(int) result.retcode_external;

               data["request"].Set(req);
               data["result"].Set(res);
               
               string t=data.Serialize();
               Print("transaction: " + t);
            }
         break;
         default: {} break;
        }
}

string CRestApi::orderDoneOrError(bool error, string funcName, CTrade &trade, string pSymbol="", string pType="") {
      CJAVal conf;
      const MqlTradeResult &r = trade.Result();

      ulong deal       = r.deal;
      ulong positionId = 0;
      // Best-effort position id from the resulting deal
      if(deal > 0) {
         positionId = (ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID);
      }
      // Fallback: scan open positions for the symbol
      if(positionId == 0 && pSymbol != "") {
         for(int i = PositionsTotal()-1; i >= 0; i--) {
            if(PositionGetSymbol(i) == pSymbol) {
               positionId = (ulong)PositionGetInteger(POSITION_IDENTIFIER);
               break;
            }
         }
      }

      conf["retcode"]          = (int)r.retcode;
      conf["retcode_external"] = (int)r.retcode_external;
      conf["order_id"]         = (ulong)r.order;       // real order ticket
      conf["deal_id"]          = deal;                 // real deal ticket (0 if none)
      conf["position_id"]      = positionId;           // best-effort
      conf["symbol"]           = pSymbol;
      conf["type"]             = pType;
      conf["price"]            = r.price;              // real fill price
      conf["volume"]           = r.volume;             // real filled volume
      conf["bid"]              = r.bid;
      conf["ask"]              = r.ask;
      conf["time"]             = fromDateTime(TimeTradeServer());
      conf["error"]            = (int)r.retcode;       // legacy
      conf["description"]      = (string)CRestApi::GetRetcodeID(r.retcode);
      conf["function"]         = (string)funcName;

      string t=conf.Serialize();
      if(debug) Print(t);

      return t;
}

//+------------------------------------------------------------------+
//| Action confirmation                                              |
//+------------------------------------------------------------------+
string CRestApi::actionDoneOrError(int lastError, string funcName) {
      CJAVal conf;
      
      conf["error"]=(string) lastError;
      conf["description"]=GetErrorID(lastError);
      conf["function"]=(string) funcName;
      
      string t=conf.Serialize();
      if(debug) Print(t);
      
      return t;
}

string CRestApi::GetRetcodeID(int retcode) { 
   switch(retcode) 
     { 
      case 10004: return("TRADE_RETCODE_REQUOTE");             break; 
      case 10006: return("TRADE_RETCODE_REJECT");              break; 
      case 10007: return("TRADE_RETCODE_CANCEL");              break; 
      case 10008: return("TRADE_RETCODE_PLACED");              break; 
      case 10009: return("TRADE_RETCODE_DONE");                break; 
      case 10010: return("TRADE_RETCODE_DONE_PARTIAL");        break; 
      case 10011: return("TRADE_RETCODE_ERROR");               break; 
      case 10012: return("TRADE_RETCODE_TIMEOUT");             break; 
      case 10013: return("TRADE_RETCODE_INVALID");             break; 
      case 10014: return("TRADE_RETCODE_INVALID_VOLUME");      break; 
      case 10015: return("TRADE_RETCODE_INVALID_PRICE");       break; 
      case 10016: return("TRADE_RETCODE_INVALID_STOPS");       break; 
      case 10017: return("TRADE_RETCODE_TRADE_DISABLED");      break; 
      case 10018: return("TRADE_RETCODE_MARKET_CLOSED");       break; 
      case 10019: return("TRADE_RETCODE_NO_MONEY");            break; 
      case 10020: return("TRADE_RETCODE_PRICE_CHANGED");       break; 
      case 10021: return("TRADE_RETCODE_PRICE_OFF");           break; 
      case 10022: return("TRADE_RETCODE_INVALID_EXPIRATION");  break; 
      case 10023: return("TRADE_RETCODE_ORDER_CHANGED");       break; 
      case 10024: return("TRADE_RETCODE_TOO_MANY_REQUESTS");   break; 
      case 10025: return("TRADE_RETCODE_NO_CHANGES");          break; 
      case 10026: return("TRADE_RETCODE_SERVER_DISABLES_AT");  break; 
      case 10027: return("TRADE_RETCODE_CLIENT_DISABLES_AT");  break; 
      case 10028: return("TRADE_RETCODE_LOCKED");              break; 
      case 10029: return("TRADE_RETCODE_FROZEN");              break; 
      case 10030: return("TRADE_RETCODE_INVALID_FILL");        break; 
      case 10031: return("TRADE_RETCODE_CONNECTION");          break; 
      case 10032: return("TRADE_RETCODE_ONLY_REAL");           break; 
      case 10033: return("TRADE_RETCODE_LIMIT_ORDERS");        break; 
      case 10034: return("TRADE_RETCODE_LIMIT_VOLUME");        break; 
      case 10035: return("TRADE_RETCODE_INVALID_ORDER");       break; 
      case 10036: return("TRADE_RETCODE_POSITION_CLOSED");     break; 
      case 10038: return("TRADE_RETCODE_INVALID_CLOSE_VOLUME");break; 
      case 10039: return("TRADE_RETCODE_CLOSE_ORDER_EXIST");   break; 
      case 10040: return("TRADE_RETCODE_LIMIT_POSITIONS");     break;  
      case 10041: return("TRADE_RETCODE_REJECT_CANCEL");       break; 
      case 10042: return("TRADE_RETCODE_LONG_ONLY");           break;
      case 10043: return("TRADE_RETCODE_SHORT_ONLY");          break;
      case 10044: return("TRADE_RETCODE_CLOSE_ONLY");          break;
      
      default: 
         return("TRADE_RETCODE_UNKNOWN="+IntegerToString(retcode)); 
         break; 
     } 
  }
  
//+------------------------------------------------------------------+
//| Get error message by error id                                    |
//+------------------------------------------------------------------+
static string CRestApi::GetErrorID(int error) { 
   switch(error) { 
      case 0:     return("ERR_SUCCESS");                       break; 
      case 4301:  return("ERR_MARKET_UNKNOWN_SYMBOL");         break;  
      case 4303:  return("ERR_MARKET_WRONG_PROPERTY");         break;
      case 4752:  return("ERR_TRADE_DISABLED");                break;
      case 4753:  return("ERR_TRADE_POSITION_NOT_FOUND");      break;
      case 4754:  return("ERR_TRADE_ORDER_NOT_FOUND");         break; 
      // Custom errors
      case 65537: return("ERR_DESERIALIZATION");               break;
      case 65538: return("ERR_WRONG_ACTION");                  break;
      case 65539: return("ERR_WRONG_ACTION_TYPE");             break;
      case ERR_TRADE_DEAL_NOT_FOUND: return("ERR_TRADE_DEAL_NOT_FOUND");          break;
      
      
      default: 
         return("ERR_CODE_UNKNOWN="+IntegerToString(error)); 
         break; 
     } 
}

//+------------------------------------------------------------------+
//| Convert timeframe string to ENUM_TIMEFRAMES                      |
//+------------------------------------------------------------------+
ENUM_TIMEFRAMES CRestApi::StringToTimeframe(string tf) {
   if(tf == "M1")  return PERIOD_M1;
   if(tf == "M5")  return PERIOD_M5;
   if(tf == "M15") return PERIOD_M15;
   if(tf == "M30") return PERIOD_M30;
   if(tf == "H1")  return PERIOD_H1;
   if(tf == "H4")  return PERIOD_H4;
   if(tf == "D1")  return PERIOD_D1;
   if(tf == "W1")  return PERIOD_W1;
   if(tf == "MN1") return PERIOD_MN1;
   return PERIOD_H1; // Default
}

//+------------------------------------------------------------------+
//| Get historical candlestick data (OHLCV)                          |
//+------------------------------------------------------------------+
string CRestApi::getCandleData(CJAVal &dataObject) {
   ResetLastError();

   // Parse parameters
   string symbol = dataObject["id"].ToStr();
   string timeframeStr = dataObject["timeframe"].ToStr();
   int count = (int)dataObject["count"].ToInt();
   int start_pos = (int)dataObject["start_pos"].ToInt();

   // Set defaults
   if(StringLen(timeframeStr) < 1) timeframeStr = "H1";
   if(count < 1) count = 100;
   if(count > 1000) count = 1000;
   if(start_pos < 0) start_pos = 0;

   // Convert timeframe string to enum
   ENUM_TIMEFRAMES timeframe = StringToTimeframe(timeframeStr);

   // Check if symbol exists
   if(!SymbolSelect(symbol, true)) {
      return actionDoneOrError(ERR_MARKET_UNKNOWN_SYMBOL, __FUNCTION__);
   }

   // Get candle data using CopyRates
   MqlRates rates[];
   ArraySetAsSeries(rates, true);

   int copied = CopyRates(symbol, timeframe, start_pos, count, rates);

   if(copied <= 0) {
      return actionDoneOrError(GetLastError(), __FUNCTION__);
   }

   // Build JSON response
   CJAVal result, candles;

   result["symbol"] = symbol;
   result["timeframe"] = timeframeStr;
   result["count"] = copied;

   for(int i = 0; i < copied; i++) {
      CJAVal candle;
      candle["time"] = fromDateTime(rates[i].time);
      candle["open"] = rates[i].open;
      candle["high"] = rates[i].high;
      candle["low"] = rates[i].low;
      candle["close"] = rates[i].close;
      candle["tick_volume"] = rates[i].tick_volume;
      candle["spread"] = rates[i].spread;
      candle["real_volume"] = rates[i].real_volume;

      candles.Add(candle);
   }

   result["candles"].Set(candles);

   string t = result.Serialize();
   if(debug) Print(t);

   return t;
}

//+------------------------------------------------------------------+
//| Get full account properties                                       |
//+------------------------------------------------------------------+
string CRestApi::getAccount() {
   CJAVal info;

   info["company"] = AccountInfoString(ACCOUNT_COMPANY);
   info["currency"] = AccountInfoString(ACCOUNT_CURRENCY);
   info["server"] = AccountInfoString(ACCOUNT_SERVER);
   info["name"] = AccountInfoString(ACCOUNT_NAME);
   info["number"] = AccountInfoInteger(ACCOUNT_LOGIN);
   info["leverage"] = AccountInfoInteger(ACCOUNT_LEVERAGE);
   info["balance"] = AccountInfoDouble(ACCOUNT_BALANCE);
   info["equity"] = AccountInfoDouble(ACCOUNT_EQUITY);
   info["margin"] = AccountInfoDouble(ACCOUNT_MARGIN);
   info["margin_free"] = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   info["margin_level"] = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
   info["profit"] = AccountInfoDouble(ACCOUNT_PROFIT);
   info["credit"] = AccountInfoDouble(ACCOUNT_CREDIT);
   info["trade_mode"] = EnumToString(ENUM_ACCOUNT_TRADE_MODE(AccountInfoInteger(ACCOUNT_TRADE_MODE)));
   info["margin_so_mode"] = EnumToString(ENUM_ACCOUNT_STOPOUT_MODE(AccountInfoInteger(ACCOUNT_MARGIN_SO_MODE)));
   info["margin_so_so"] = AccountInfoDouble(ACCOUNT_MARGIN_SO_SO);
   info["margin_so_call"] = AccountInfoDouble(ACCOUNT_MARGIN_SO_CALL);
   info["trade_allowed"] = AccountInfoInteger(ACCOUNT_TRADE_ALLOWED);
   info["trade_expert"] = AccountInfoInteger(ACCOUNT_TRADE_EXPERT);
   info["trade_fifo"] = AccountInfoInteger(ACCOUNT_TRADE_FIFO);
   info["currency_digits"] = AccountInfoInteger(ACCOUNT_CURRENCY_DIGITS);
   info["stopout_mode"] = EnumToString(ENUM_ACCOUNT_STOPOUT_MODE(AccountInfoInteger(ACCOUNT_STOPOUT_MODE)));
   info["stopout_level"] = AccountInfoDouble(ACCOUNT_MARGIN_SO_SO);

   string t = info.Serialize();
   if(debug) Print(t);
   return t;
}

//+------------------------------------------------------------------+
//| Get all symbol names                                             |
//+------------------------------------------------------------------+
string CRestApi::getSymbols() {
   CJAVal data;

   int total = SymbolsTotal(false);
   for(int i = 0; i < total; i++) {
      CJAVal item;
      item["name"] = SymbolName(i, false);
      data.Add(item);
   }

   string t = data.Serialize();
   if(debug) Print(t);
   return t;
}

//+------------------------------------------------------------------+
//| Get full symbol info                                             |
//+------------------------------------------------------------------+
string CRestApi::getSymbolInfoFull(string name) {
   CJAVal info;

   if(!SymbolSelect(name, true))
      return actionDoneOrError(ERR_MARKET_UNKNOWN_SYMBOL, __FUNCTION__);

   MqlTick last_tick;
   if(!SymbolInfoTick(name, last_tick))
      return actionDoneOrError(ERR_MARKET_UNKNOWN_SYMBOL, __FUNCTION__);

   info["ask"] = last_tick.ask;
   info["bid"] = last_tick.bid;
   info["time"] = fromDateTime(last_tick.time);
   info["tick_size"] = SymbolInfoDouble(name, SYMBOL_TRADE_TICK_SIZE);
   info["tick_value"] = SymbolInfoDouble(name, SYMBOL_TRADE_TICK_VALUE);
   info["contract_size"] = SymbolInfoDouble(name, SYMBOL_TRADE_CONTRACT_SIZE);
   info["min_volume"] = SymbolInfoDouble(name, SYMBOL_VOLUME_MIN);
   info["max_volume"] = SymbolInfoDouble(name, SYMBOL_VOLUME_MAX);
   info["volume_step"] = SymbolInfoDouble(name, SYMBOL_VOLUME_STEP);
   info["spread"] = (int)SymbolInfoInteger(name, SYMBOL_SPREAD);
   info["digits"] = (int)SymbolInfoInteger(name, SYMBOL_DIGITS);
   info["swap_long"] = SymbolInfoDouble(name, SYMBOL_SWAP_LONG);
   info["swap_short"] = SymbolInfoDouble(name, SYMBOL_SWAP_SHORT);
   info["trade_mode"] = EnumToString(ENUM_SYMBOL_TRADE_MODE(SymbolInfoInteger(name, SYMBOL_TRADE_MODE)));
   info["trade_exemode"] = EnumToString(ENUM_SYMBOL_TRADE_EXECUTION(SymbolInfoInteger(name, SYMBOL_TRADE_EXEMODE)));
   info["trade_filling"] = SymbolInfoInteger(name, SYMBOL_TRADE_FILLING);
   info["trade_stops_level"] = (int)SymbolInfoInteger(name, SYMBOL_TRADE_STOPS_LEVEL);
   info["trade_freeze_level"] = (int)SymbolInfoInteger(name, SYMBOL_TRADE_FREEZE_LEVEL);

   long sessionOpen = SymbolInfoInteger(name, SYMBOL_SESSION_OPEN);
   long sessionClose = SymbolInfoInteger(name, SYMBOL_SESSION_CLOSE);
   if(sessionOpen >= 0)
      info["session_open"] = (int)sessionOpen;
   else
      info["session_open"] = -1;
   if(sessionClose >= 0)
      info["session_close"] = (int)sessionClose;
   else
      info["session_close"] = -1;

   string t = info.Serialize();
   if(debug) Print(t);
   return t;
}

//+------------------------------------------------------------------+
//| Get tick data for a symbol                                       |
//+------------------------------------------------------------------+
string CRestApi::getTick(string symbol) {
   CJAVal info;
   MqlTick tick;

   if(!SymbolInfoTick(symbol, tick))
      return actionDoneOrError(ERR_MARKET_UNKNOWN_SYMBOL, __FUNCTION__);

   info["bid"] = tick.bid;
   info["ask"] = tick.ask;
   info["last"] = tick.last;
   info["volume"] = tick.volume;
   info["time"] = fromDateTime(tick.time);
   info["time_msc"] = (long)tick.time_msc;
   info["flags"] = (int)tick.flags;

   string t = info.Serialize();
   if(debug) Print(t);
   return t;
}

//+------------------------------------------------------------------+
//| Get PnL summary grouped by symbol                                |
//+------------------------------------------------------------------+
string CRestApi::getPositionsPnl() {
   CJAVal data;
   CPositionInfo myposition;

   int positionsTotal = PositionsTotal();
   double totalProfit = 0.0;

   // Temporary arrays to hold per-symbol sums
   string symbols[];
   double profits[];
   double swaps[];
   int counts[];

   for(int i = 0; i < positionsTotal; i++) {
      if(!myposition.SelectByIndex(i)) continue;

      string sym = PositionGetString(POSITION_SYMBOL);
      double profit = PositionGetDouble(POSITION_PROFIT);
      double swap = PositionGetDouble(POSITION_SWAP);
      totalProfit += profit + swap;

      // Find or add symbol entry
      int idx = -1;
      for(int j = 0; j < ArraySize(symbols); j++) {
         if(symbols[j] == sym) { idx = j; break; }
      }
      if(idx == -1) {
         idx = ArraySize(symbols);
         ArrayResize(symbols, idx + 1);
         ArrayResize(profits, idx + 1);
         ArrayResize(swaps, idx + 1);
         ArrayResize(counts, idx + 1);
         symbols[idx] = sym;
         profits[idx] = 0.0;
         swaps[idx] = 0.0;
         counts[idx] = 0;
      }
      profits[idx] += profit;
      swaps[idx] += swap;
      counts[idx] += 1;
   }

   for(int i = 0; i < ArraySize(symbols); i++) {
      CJAVal item;
      item["symbol"] = symbols[i];
      item["profit"] = profits[i];
      item["swap"] = swaps[i];
      item["total"] = profits[i] + swaps[i];
      item["positions"] = counts[i];
      data.Add(item);
   }

   CJAVal result;
   result["total_profit"] = totalProfit;
   result["positions_total"] = positionsTotal;
   result["symbols"].Set(data);

   string t = result.Serialize();
   if(debug) Print(t);
   return t;
}

//+------------------------------------------------------------------+
//| Calculate margin for a symbol                                     |
//+------------------------------------------------------------------+
string CRestApi::getMargin(string symbol) {
   CJAVal info;

   double volume = 0.01;
   ENUM_ORDER_TYPE orderType = ORDER_TYPE_BUY;

   info["symbol"] = symbol;
   info["volume"] = volume;
   info["type"] = "ORDER_TYPE_BUY";

   double margin = 0.0;
   if(!OrderCalcMargin(orderType, symbol, volume, SymbolInfoDouble(symbol, SYMBOL_ASK), 0.0, margin))
      return actionDoneOrError(ERR_MARKET_UNKNOWN_SYMBOL, __FUNCTION__);

   info["margin"] = margin;

   string t = info.Serialize();
   if(debug) Print(t);
   return t;
}

//+------------------------------------------------------------------+
//| Get account history - deal profit summary grouped by day          |
//+------------------------------------------------------------------+
string CRestApi::getAccountHistory(CJAVal &dataObject) {
   CJAVal result;

   datetime from = 0;
   datetime to = TimeCurrent();

   if(dataObject.HasKey("from", jtSTR)) {
      from = StringToTime(dataObject["from"].ToStr());
   }
   if(dataObject.HasKey("to", jtSTR)) {
      to = StringToTime(dataObject["to"].ToStr());
   }

   if(!HistorySelect(from, to))
      return actionDoneOrError(GetLastError(), __FUNCTION__);

   int dealsTotal = HistoryDealsTotal();
   CJAVal days;

   // Group profits by date string
   string dateKeys[];
   double dayProfits[];
   int dayCounts[];
   double totalProfit = 0.0;

   for(int i = 0; i < dealsTotal; i++) {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;

      double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
      double commission = HistoryDealGetDouble(ticket, DEAL_COMMISSION);
      datetime dealTime = (datetime)HistoryDealGetInteger(ticket, DEAL_TIME);
      string dateStr = TimeToString(dealTime, TIME_DATE);

      totalProfit += profit + commission;

      int idx = -1;
      for(int j = 0; j < ArraySize(dateKeys); j++) {
         if(dateKeys[j] == dateStr) { idx = j; break; }
      }
      if(idx == -1) {
         idx = ArraySize(dateKeys);
         ArrayResize(dateKeys, idx + 1);
         ArrayResize(dayProfits, idx + 1);
         ArrayResize(dayCounts, idx + 1);
         dateKeys[idx] = dateStr;
         dayProfits[idx] = 0.0;
         dayCounts[idx] = 0;
      }
      dayProfits[idx] += profit + commission;
      dayCounts[idx] += 1;
   }

   for(int i = 0; i < ArraySize(dateKeys); i++) {
      CJAVal day;
      day["date"] = dateKeys[i];
      day["profit"] = dayProfits[i];
      day["deals"] = dayCounts[i];
      days.Add(day);
   }

   result["total_profit"] = totalProfit;
   result["total_deals"] = dealsTotal;
   result["days"].Set(days);

   string t = result.Serialize();
   if(debug) Print(t);
   return t;
}

//+------------------------------------------------------------------+
//| Close all open positions                                          |
//+------------------------------------------------------------------+
string CRestApi::tradeCloseAll() {
   CTrade trade;
   CJAVal results;

   int positionsTotal = PositionsTotal();
   int closed = 0;
   int failed = 0;

   for(int i = positionsTotal - 1; i >= 0; i--) {
      if(!PositionSelectByIndex(i)) continue;

      ulong ticket = PositionGetInteger(POSITION_TICKET);
      if(trade.PositionClose(ticket)) {
         closed++;
         CJAVal item;
         item["ticket"] = (long)ticket;
         item["symbol"] = PositionGetString(POSITION_SYMBOL);
         item["result"] = "ok";
         item["retcode"] = (int)trade.ResultRetcode();
         results.Add(item);
      } else {
         failed++;
         CJAVal item;
         item["ticket"] = (long)ticket;
         item["symbol"] = PositionGetString(POSITION_SYMBOL);
         item["result"] = "error";
         item["retcode"] = (int)trade.ResultRetcode();
         item["description"] = CRestApi::GetRetcodeID(trade.ResultRetcode());
         results.Add(item);
      }
   }

   CJAVal summary;
   summary["closed"] = closed;
   summary["failed"] = failed;
   summary["total"] = positionsTotal;
   summary["trades"].Set(results);

   string t = summary.Serialize();
   if(debug) Print(t);
   return t;
}

//+------------------------------------------------------------------+
//| Close positions matching a symbol                                 |
//+------------------------------------------------------------------+
string CRestApi::tradeCloseSymbol(string symbol) {
   CTrade trade;
   CJAVal results;

   int positionsTotal = PositionsTotal();
   int closed = 0;
   int failed = 0;

   for(int i = positionsTotal - 1; i >= 0; i--) {
      if(!PositionSelectByIndex(i)) continue;

      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;

      ulong ticket = PositionGetInteger(POSITION_TICKET);
      if(trade.PositionClose(ticket)) {
         closed++;
         CJAVal item;
         item["ticket"] = (long)ticket;
         item["result"] = "ok";
         item["retcode"] = (int)trade.ResultRetcode();
         results.Add(item);
      } else {
         failed++;
         CJAVal item;
         item["ticket"] = (long)ticket;
         item["result"] = "error";
         item["retcode"] = (int)trade.ResultRetcode();
         item["description"] = CRestApi::GetRetcodeID(trade.ResultRetcode());
         results.Add(item);
      }
   }

   CJAVal summary;
   summary["symbol"] = symbol;
   summary["closed"] = closed;
   summary["failed"] = failed;
   summary["trades"].Set(results);

   string t = summary.Serialize();
   if(debug) Print(t);
   return t;
}

//+------------------------------------------------------------------+
//| Execute a batch of trades (cap 20)                                |
//+------------------------------------------------------------------+
string CRestApi::tradeBatch(CJAVal &dataObject) {
   CJAVal results;

   if(!dataObject.HasKey("trades", jtARRAY))
      return actionDoneOrError(65538, __FUNCTION__);

   CJAVal *trades = dataObject["trades"];
   int count = trades.Size();
   int maxOps = 20;
   if(count > maxOps) count = maxOps;

   for(int i = 0; i < count; i++) {
      CJAVal *tradeData = trades[i];
      CJAVal result;
      result.Deserialize(tradingModule(tradeData));
      results.Add(result);
   }

   CJAVal batchResult;
   batchResult["count"] = count;
   if(trades.Size() > maxOps)
      batchResult["cap"] = maxOps;
   batchResult["results"].Set(results);

   string t = batchResult.Serialize();
   if(debug) Print(t);
   return t;
}

string CRestApi::fromDateTime(datetime param) {
   CString s_iso8601;

   s_iso8601.Assign(TimeToString(param, TIME_DATE|TIME_MINUTES|TIME_SECONDS));
   s_iso8601.Replace(" ", "T");
   s_iso8601.Replace(".", "-");
   s_iso8601.Append(".000Z");
   return s_iso8601.Str();
}

//+------------------------------------------------------------------+
//| Parse a from-query param to a datetime (0 if absent/invalid)     |
//+------------------------------------------------------------------+
datetime CRestApi::parseFromParam(string s) {
   s = TrimString(s);
   if(s == "") return 0;
   // Integer epoch: 13 digits = millis (divide by 1000), 10 digits = seconds
   int len = StringLen(s);
   bool allDigits = (StringFind(s, "-") == -1);
   if(allDigits && len >= 10) {
      long v = StringToInteger(s);
      if(len == 13) v /= 1000;          // millis -> seconds
      return (datetime)v;
   }
   // ISO-8601 string
   return StringToTime(s);
}

//+------------------------------------------------------------------+
//| Parse a to-query param to a datetime (TimeCurrent() if absent)   |
//+------------------------------------------------------------------+
datetime CRestApi::parseToParam(string s) {
   s = TrimString(s);
   if(s == "") return TimeCurrent();
   int len = StringLen(s);
   bool allDigits = (StringFind(s, "-") == -1);
   if(allDigits && len >= 10) {
      long v = StringToInteger(s);
      if(len == 13) v /= 1000;
      return (datetime)v;
   }
   return StringToTime(s);
}

//+------------------------------------------------------------------+
//| Readable deal exit reason                                         |
//+------------------------------------------------------------------+
string CRestApi::dealReasonString(int reason) {
   switch(reason) {
      case 0:  return "client";         // DEAL_REASON_CLIENT
      case 1:  return "expert";         // DEAL_REASON_EXPERT
      case 2:  return "dealer";         // DEAL_REASON_DEALER
      case 3:  return "stop loss";      // DEAL_REASON_SL
      case 4:  return "take profit";    // DEAL_REASON_TP
      case 5:  return "stop out";       // DEAL_REASON_SO
      case 6:  return "rollover";       // DEAL_REASON_ROLLOVER
      case 7:  return "external";       // DEAL_REASON_EXTERNAL
      case 8:  return "variation margin";// DEAL_REASON_VMARGIN
      case 9:  return "split";          // DEAL_REASON_SPLIT
      default: return EnumToString((ENUM_DEAL_REASON)reason);
   }
}

//+------------------------------------------------------------------+
//| Readable deal entry type                                          |
//+------------------------------------------------------------------+
string CRestApi::dealEntryString(int entry) {
   switch(entry) {
      case 0: return "in";       // DEAL_ENTRY_IN
      case 1: return "out";      // DEAL_ENTRY_OUT
      case 2: return "inout";    // DEAL_ENTRY_INOUT
      case 3: return "out_by";   // DEAL_ENTRY_OUT_BY
      default: return EnumToString((ENUM_DEAL_ENTRY)entry);
   }
}

//+------------------------------------------------------------------+
//| Readable order reason                                              |
//+------------------------------------------------------------------+
string CRestApi::orderReasonString(int reason) {
   switch(reason) {
      case 0:  return "client";
      case 1:  return "expert";
      case 2:  return "dealer";
      case 3:  return "stop loss";
      case 4:  return "take profit";
      case 5:  return "stop out";
      case 6:  return "rollover";
      case 7:  return "external";
      case 8:  return "variation margin";
      case 9:  return "split";
      default: return EnumToString((ENUM_ORDER_REASON)reason);
   }
}
