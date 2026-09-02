# MT5 REST Bridge Production Features — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add 8 production features to the live MT5 REST bridge (`/trade` tickets, `/deals` paging+filters+reasons, `/history` filters+fill, `/positions` profit/swap/comment, `/symbols` full spec, `/ping`, stability, Swagger) — MQL5-only, additive to the HTTP contract.

**Architecture:** Modify `MQL5/Include/RestApi.mqh` handlers + dispatch and extend `MQL5/Libraries/swagger.json`. No C++ DLL change: query params already flow into the MQL5 command body as strings (microsvc_controller.cpp:350-352), and Swagger is read live from disk (microsvc_controller.cpp:302-318).

**Tech Stack:** MQL5 (MetaEditor, CTrade/COrderInfo/CPositionInfo, CJAVal from `json.mqh`). No build available in this environment — verify by MetaEditor compile (user-side) + code review.

**Spec:** `docs/superpowers/specs/2026-09-02-mt5-rest-features-design.md`

## Global Constraints

- Additive only: existing JSON camelCase field names and meanings never change or disappear.
- Command envelope `{"version":"1","request_id":"<uuid>","command":"<action>",...}`; command cap ~7000 bytes (413).
- File encodings: `RestApi.mqh` is **UTF-8 no BOM**. Edit tools (Edit/Write) are fine for it. Do NOT touch `RestApi.mq5` (UTF-16) unless required.
- Parse all query params from `CJAVal` as strings; clamp `offset>=0`, `limit` default 100, clamp `1..500`.
- Bounded `HistorySelect(from, to)` everywhere — never `HistorySelect(0, TimeCurrent())` in heavy handlers.
- Keep `if(debug) Print(...)` lines as-is; add one always-on slow-command warning (>3000ms).
- Swagger is UTF-8, served live; update it to match new schemas.
- Commit after each task with a clear message; stay on `main`.

---

### Task 1: Add helper functions to `RestApi.mqh`

**Files:**
- Modify: `MQL5/Include/RestApi.mqh` (add helpers near `fromDateTime`, line ~1469)

**Interfaces:**
- Produces:
  - `datetime parseFromParam(string s)` → parsed `datetime` or `0` (see §3 of spec).
  - `datetime parseToParam(string s)` → parsed `datetime` or `TimeCurrent()`.
  - `string dealReasonString(int reason)` → readable reason string.
  - `string dealEntryString(int entry)` → readable entry string.
  - `string orderReasonString(int reason)` → readable order reason string.

- [ ] **Step 1: Add the helper implementations**

Add these immediately after the `fromDateTime` function (end of file). Content:

```mql5
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
```

- [ ] **Step 2: Declare the helpers in the class header**

In the `class CRestApi` declaration (near the other private method declarations, around line 57-70), add:

```mql5
   datetime parseFromParam(string s);
   datetime parseToParam(string s);
   string   dealReasonString(int reason);
   string   dealEntryString(int entry);
   string   orderReasonString(int reason);
```

- [ ] **Step 3: Verify no syntax errors by inspection**

Open the file in MetaEditor (user-side) or grep — confirm the helpers parse as top-level
`string CRestApi::funcName(...)` members matching the declarations. Confirm `TrimString`,
`StringToTime`, `StringToInteger`, `EnumToString` are available (they are standard MQL5).

- [ ] **Step 4: Commit**

```bash
git add MQL5/Include/RestApi.mqh
git commit -m "feat(mql5): add param/date/reason/entry helper functions"
```

---

### Task 2: `/trade` real tickets in `orderDoneOrError` + `tradingModule`

**Files:**
- Modify: `MQL5/Include/RestApi.mqh` — `orderDoneOrError` (line ~871) and `tradingModule` (line ~717)

**Interfaces:**
- Consumes: `orderDoneOrError(bool error, string funcName, CTrade &trade, string pSymbol="", string pType="")`
- Produces: `/trade` response object with real `order_id`, `deal_id`, `position_id`, `symbol`,
  `type`, `price` (fill), `volume`, `retcode`, `retcode_external`, `time`, plus legacy
  `error`, `description`, `bid`, `ask`, `function`.

- [ ] **Step 1: Rewrite `orderDoneOrError`**

Replace the whole body of `CRestApi::orderDoneOrError` (currently lines 871-887) with:

```mql5
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

   string t = conf.Serialize();
   if(debug) Print(t);
   return t;
}
```

- [ ] **Step 2: Update the declaration for `orderDoneOrError`**

In the class header, change the declaration to add the two optional params:

```mql5
   string orderDoneOrError(bool error, string funcName, CTrade &trade, string pSymbol="", string pType="");
```

- [ ] **Step 3: Thread symbol + type through `tradingModule` calls**

In `tradingModule`, capture the resolved order type and symbol strings and pass them to
`orderDoneOrError`. There are many call sites; wrap each return with the new args. For the
**market** branch (currently lines 748-750) the order type string is `actionType` and symbol is
`symbol`. Example for the BUY/SELL market branch:

```mql5
            if(trade.PositionOpen(symbol,orderType,volume,price,SL,TP,comment)) {
               string tStr = EnumToString(orderType);   // "ORDER_TYPE_BUY" etc.
               return orderDoneOrError(false, __FUNCTION__, trade, symbol, tStr);
            }
```

Apply the same pattern to every other `return orderDoneOrError(false, __FUNCTION__, trade);`
in `tradingModule`:
- BuyLimit/SellLimit/BuyStop/SellStop branches: pass `(symbol, actionType)`.
- POSITION_MODIFY / POSITION_PARTIAL / POSITION_CLOSE_ID / POSITION_CLOSE_SYMBOL: pass
  `(symbol, "")` (no order type for position ops).
- ORDER_MODIFY / ORDER_CANCEL: pass `(symbol, "")`.
The final `return orderDoneOrError(true, __FUNCTION__, trade);` (line 817, order not completed)
stays with the legacy 3-arg form (defaults fill symbol/type as empty).

- [ ] **Step 3b: Fix `tradingModule` symbol guard**

The current guard `if(!(symbol==_Symbol)) actionDoneOrError(...)` calls `actionDoneOrError`
without `return`, so execution continues with a non-matching symbol. Fix to return early:

```mql5
   if(!(symbol==_Symbol)) return actionDoneOrError(ERR_MARKET_UNKNOWN_SYMBOL, __FUNCTION__);
```

Also add `string tStr = "";` local before market branch (or reuse `actionType`) so `type` is
always a meaningful string for orders.

- [ ] **Step 4: Verify by inspection**

- [ ] **Step 5: Commit**

```bash
git add MQL5/Include/RestApi.mqh
git commit -m "feat(mql5): /trade returns real order/deal/position tickets and fill price"
```

---

### Task 3: `/deals` pagination, filters, reasons (rewrite `getTransactions`)

**Files:**
- Modify: `MQL5/Include/RestApi.mqh` — `getTransactions` (line ~471)

**Interfaces:**
- Consumes: `parseFromParam`, `parseToParam`, `dealReasonString`, `dealEntryString` (Task 1)
- Produces: `/deals` → `{"deals":[ {...} ], "total": N}`

- [ ] **Step 1: Replace the body of `getTransactions`**

Replace the whole `CRestApi::getTransactions(CJAVal &dataObject)` body (lines 471-518) with:

```mql5
string CRestApi::getTransactions(CJAVal &dataObject) {
   ResetLastError();

   string   positionFilter = dataObject["position_id"].ToStr();
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
   out["deals"].Set(data);   // attach the deal array under key "deals" (verified pattern)
   out["total"] = (ulong)total;

   string t = out.Serialize();
   if(debug) Print(t);
   return t;
}
```

> NOTES:
> - `ArrayResize(collected, ...)` with `HistoryDealGetTicket(i)` indexes the *selected* window
>   (respecting `from`/`to`); our filters run on top. `total` is the **filtered** count, so paging
>   is correct. The collection loop iterates `dealsTotal-1 .. 0` so `collected[0]` is the newest —
>   paging preserves newest-first order.
> - How to attach an array under a named key in this `json.mqh`: build the array as a standalone
>   `CJAVal data;` via `data.Add(deal)`, then attach with `out["deals"].Set(data);`. This is the
>   exact pattern already used in `getAccountHistory` (line 1338: `result["days"].Set(days);`).
>   Do **NOT** use `out["deals"].Add(deal)` — `operator[](string)` creates an object element, and
>   `Add` on it would serialize incorrectly. The `.Set(arrayVal)` form is verified.

- [ ] **Step 2: Verify by inspection**

- [ ] **Step 4: Commit**

```bash
git add MQL5/Include/RestApi.mqh
git commit -m "feat(mql5): /deals add total+pagination, position_id/symbol/from/to filters, real reasons"
```

---

### Task 4: `/history` filters + real fill price (rewrite `getOrdersHistory` + dispatch)

**Files:**
- Modify: `MQL5/Include/RestApi.mqh` — `getOrdersHistory` (line ~565) and dispatch line ~192

**Interfaces:**
- Consumes: `parseFromParam`, `parseToParam`, `orderReasonString` (Task 1)
- Produces: `/history` → `{"orders":[ {...} ], "total": N}`; `fill` = real fill for filled orders

- [ ] **Step 1: Change the declaration**

In the class header change `string getOrdersHistory();` → `string getOrdersHistory(CJAVal &dataObject);`

- [ ] **Step 2: Update dispatch**

Change line ~190-192 from:

```mql5
          if(id != NULL)      
             response = getOrderHistory(id.ToInt());
          else
             response = getOrdersHistory();
```

to (only the else branch changes):

```mql5
          else
             response = getOrdersHistory(jCommand);
```

- [ ] **Step 3: Replace the body of `getOrdersHistory`**

Replace the whole `CRestApi::getOrdersHistory()` body (lines 565-605) with:

```mql5
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
   out["orders"].Set(data);   // attach the order array under key "orders" (verified pattern)
   out["total"] = (ulong)total;

   string t = out.Serialize();
   if(debug) Print(t);
   return t;
}
```

> Attach the built array with `out["orders"].Set(data);` — the same verified pattern as
> `getAccountHistory` line 1338 (`result["days"].Set(days);`). Do NOT append per-element with
> `out["orders"].Add(order)` (wrong shape). The paging loop already collects into `data` exactly
> once, so `out["orders"].Set(data)` yields one array of length `(end-start)` under `"orders"`.

- [ ] **Step 4: Verify by inspection**

- [ ] **Step 5: Commit**

```bash
git add MQL5/Include/RestApi.mqh
git commit -m "feat(mql5): /history filters, real fill price, wrap with total"
```

---

### Task 5: `/positions` profit/swap/comment

**Files:**
- Modify: `MQL5/Include/RestApi.mqh` — `getPositions` (line ~431)

**Interfaces:**
- Produces: each `/positions` item gains `profit`, `swap`, `comment` (additive; keeps bare array shape).

- [ ] **Step 1: Add three fields in `getPositions`**

Inside the `if(myposition.SelectByIndex(i))` block, after the existing `position["price_current"]` line (line ~455), add:

```mql5
               position["profit"]  = PositionGetDouble(POSITION_PROFIT);
               position["swap"]    = PositionGetDouble(POSITION_SWAP);
               position["comment"] = PositionGetString(POSITION_COMMENT);
```

- [ ] **Step 2: Verify by inspection** — `/positions` remains a bare array (no wrap), only adds 3 fields.

- [ ] **Step 3: Commit**

```bash
git add MQL5/Include/RestApi.mqh
git commit -m "feat(mql5): /positions expose floating profit, swap, comment"
```

---

### Task 6: `/symbols` list spec + `/symbols/{name}` full spec

**Files:**
- Modify: `MQL5/Include/RestApi.mqh` — `getSymbols` (line ~1097), `getSymbolInfoFull` (line ~1115)

**Interfaces:**
- Produces: `/symbols` list items gain `digits, point, spread, min_volume, max_volume,
  volume_step, trade_mode, trade_exemode, session_open, session_close`;
  `/symbols/{name}` object gains spec fields (additive).

- [ ] **Step 1: Extend `getSymbols`**

Replace the body of `CRestApi::getSymbols()` (lines 1097-1110) with:

```mql5
string CRestApi::getSymbols() {
   CJAVal data;

   int total = SymbolsTotal(false);
   for(int i = 0; i < total; i++) {
      CJAVal item;
      string name = SymbolName(i, false);
      if(!SymbolSelect(name, true)) {
         item["name"] = name;
         data.Add(item);
         continue;
      }
      item["name"]        = name;
      item["digits"]      = (int)SymbolInfoInteger(name, SYMBOL_DIGITS);
      item["point"]       = (double)SymbolInfoDouble(name, SYMBOL_POINT);
      item["spread"]      = (int)SymbolInfoInteger(name, SYMBOL_SPREAD);
      item["min_volume"]  = SymbolInfoDouble(name, SYMBOL_VOLUME_MIN);
      item["max_volume"]  = SymbolInfoDouble(name, SYMBOL_VOLUME_MAX);
      item["volume_step"] = SymbolInfoDouble(name, SYMBOL_VOLUME_STEP);
      item["trade_mode"]  = EnumToString((ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(name, SYMBOL_TRADE_MODE));
      item["trade_exemode"] = EnumToString((ENUM_SYMBOL_TRADE_EXECUTION)SymbolInfoInteger(name, SYMBOL_TRADE_EXEMODE));
      item["session_open"]  = (int)SymbolInfoInteger(name, SYMBOL_SESSION_OPEN);
      item["session_close"] = (int)SymbolInfoInteger(name, SYMBOL_SESSION_CLOSE);
      data.Add(item);
   }

   string t = data.Serialize();
   if(debug) Print(t);
   return t;
}
```

- [ ] **Step 2: Extend `getSymbolInfoFull`**

After the existing `trade_freeze_level` line (line ~1142) and before the `session_open` block,
add these spec fields (keep all existing fields):

```mql5
   info["point"]             = (double)SymbolInfoDouble(name, SYMBOL_POINT);
   info["ticks_book_depth"]  = (int)SymbolInfoInteger(name, SYMBOL_TICKS_BOOKDEPTH);
   info["margin_currency"]   = SymbolInfoString(name, SYMBOL_CURRENCY_MARGIN);
   info["profit_currency"]   = SymbolInfoString(name, SYMBOL_CURRENCY_PROFIT);
   info["trade_currency"]    = SymbolInfoString(name, SYMBOL_CURRENCY_TRADE);
   info["base_currency"]     = SymbolInfoString(name, SYMBOL_CURRENCY_BASE);
   info["quote_currency"]    = SymbolInfoString(name, SYMBOL_CURRENCY_QUOTE);
   info["trade_calc_mode"]   = EnumToString((ENUM_SYMBOL_TRADE_CALC_MODE)SymbolInfoInteger(name, SYMBOL_TRADE_CALC_MODE));
   info["swap_mode"]         = EnumToString((ENUM_SYMBOL_SWAP_MODE)SymbolInfoInteger(name, SYMBOL_SWAP_MODE));
   info["swap_rollover3days"]= (int)SymbolInfoInteger(name, SYMBOL_SWAP_ROLLOVER3DAYS);
   info["expiration_mode"]   = EnumToString((ENUM_SYMBOL_EXPIRATION_MODE)SymbolInfoInteger(name, SYMBOL_EXPIRATION_MODE));
   info["volume_limit"]      = SymbolInfoDouble(name, SYMBOL_VOLUME_LIMIT);
   info["margin_initial"]    = SymbolInfoDouble(name, SYMBOL_MARGIN_INITIAL);
   info["margin_maintenance"]= SymbolInfoDouble(name, SYMBOL_MARGIN_MAINTENANCE);
```

> Enum types `ENUM_SYMBOL_TRADE_CALC_MODE`, `ENUM_SYMBOL_SWAP_MODE`,
> `ENUM_SYMBOL_EXPIRATION_MODE` are standard MQL5 enums. If a given build flags one as unknown
> (older builds), substitute `EnumToString((ENUM_SYMBOL_TRADE_CALC_MODE)v)` is fine; if the enum
> name doesn't exist in the installed build, fall back to emitting the raw integer
> `(int)SymbolInfoInteger(...)` for that one field. Confirm against the installed MetaEditor
> during compile.

- [ ] **Step 3: Verify by inspection**

- [ ] **Step 4: Commit**

```bash
git add MQL5/Include/RestApi.mqh
git commit -m "feat(mql5): /symbols fuller list spec and /symbols/{name} full spec"
```

---

### Task 7: `/ping` endpoint + per-command slow warning

**Files:**
- Modify: `MQL5/Include/RestApi.mqh` — add `getPing` handler, add `ping` dispatch branch, add elapsed timing in `Processing` (line ~150 and ~338)

**Interfaces:**
- Produces: `GET /ping` → `{"pong":true,"time":...,"timestamp":...,"terminal_build":...,"deals_total":...,"orders_total":...,"positions_total":...,"server":...,"account":...,"version":"1"}`

- [ ] **Step 1: Add `getPing` handler**

Add after `getBalanceInfo` (line ~426):

```mql5
//+------------------------------------------------------------------+
//| Ping liveness endpoint                                            |
//+------------------------------------------------------------------+
string CRestApi::getPing() {
   CJAVal out;
   out["pong"]           = true;
   out["time"]           = fromDateTime(TimeTradeServer());
   out["timestamp"]      = (ulong)TimeCurrent();
   out["terminal_build"] = (int)TerminalInfoInteger(TERMINAL_BUILD);
   int deals  = 0, orders = 0;
   if(HistorySelect(0, TimeCurrent())) {
      deals  = HistoryDealsTotal();
      orders = HistoryOrdersTotal();
   }
   out["deals_total"]     = deals;
   out["orders_total"]    = orders;
   out["positions_total"] = PositionsTotal();
   out["server"]          = AccountInfoString(ACCOUNT_SERVER);
   out["account"]         = (ulong)AccountInfoInteger(ACCOUNT_LOGIN);
   out["version"]         = "1";
   return out.Serialize();
}
```

Declare `string getPing();` in the class header.

- [ ] **Step 2: Add `ping` dispatch branch**

In `Processing()`, after the `trade_batch` branch (line ~260), add:

```mql5
      if(action == "ping") {
         response = getPing();
      }
```

- [ ] **Step 3: Add per-command elapsed timing**

In `Processing()`, `ulong _t0;` must be declared and assigned as early as possible so timing
covers the whole handler. Place it right after `command = CharArrayToString(_command);` (line
~134), i.e. inside the `if(r == 1)` block and before `jCommand.Deserialize(...)`:

```mql5
      command = CharArrayToString( _command );
      ulong _t0 = GetTickCount64();
```

And just before `SetCommandResponse(_command, _response)` (line ~339), add:

```mql5
   ulong _elapsed = GetTickCount64() - _t0;
   if(_elapsed > 3000)
      Print("REST: slow command '" + action + "' took " + (string)_elapsed + " ms");
```

> `_t0` is declared inside `if(r == 1)`, `SetCommandResponse` is also inside that block, so
> scope matches. `action` is defined at line 142 (before the elapsed check), so it is in scope.

- [ ] **Step 4: Verify by inspection** — confirm `_t0` declared on the first line of the
  `if(r == 1)` block before every handler, and the elapsed `Print` guards against empty string
  concatenation (all values are strings via `(string)` casts).

- [ ] **Step 5: Commit**

```bash
git add MQL5/Include/RestApi.mqh
git commit -m "feat(mql5): /ping liveness endpoint and slow-command warning"
```

---

### Task 8: Stability pass — remove unbounded full-window selects

**Files:**
- Modify: `MQL5/Include/RestApi.mqh` — `getAccountInfo` (line ~392), `getBalanceInfo` (line ~414)

**Interfaces:**
- Produces: no account handler performs an unbounded full-history dump; counters become bounded/cached.

- [ ] **Step 1: Make `getAccountInfo` / `getBalanceInfo` counters cheap**

These two currently call `HistorySelect(0, TimeCurrent())` just to count
`orders_total`/`deal_total`. On live large accounts this is heavy. Replace with a bounded
window for the count:

```mql5
   // in getAccountInfo, replace the HistorySelect(0,TimeCurrent()) block:
   if (HistorySelect(TimeCurrent() - PeriodSeconds(PERIOD_D1), TimeCurrent())) {
      info["orders_total"] = OrdersTotal();
   } else {
      info["orders_total"] = 0;
   }
```

```mql5
   // in getBalanceInfo, replace the HistorySelect(0,TimeCurrent()) block:
   if (HistorySelect(TimeCurrent() - PeriodSeconds(PERIOD_D1), TimeCurrent())) {
      info["deal_total"]  = HistoryDealsTotal();
      info["orders_total"]= OrdersTotal();
   } else {
      info["deal_total"]  = 0;
      info["orders_total"]= 0;
   }
```

> This makes the count a "last 1 day" count rather than all-time. Document this in the README
> note for `/info`/`/balance` (orders_total/deal_total are last-day counts). This is an additive,
> documented behavior note — the field names/meaning remain.

- [ ] **Step 2: Audit remaining `HistorySelect(0, TimeCurrent())` occurrences**

Grep `RestApi.mqh` for `HistorySelect(0, TimeCurrent())`. After Tasks 1-4 and this task, the
only remaining pings from `getPing()` use it — which is acceptable (single lightweight count,
no record iteration). Confirm no handler iterates the full history without a `limit` cap.

- [ ] **Step 3: Verify by inspection**

- [ ] **Step 4: Commit**

```bash
git add MQL5/Include/RestApi.mqh
git commit -m "perf(mql5): bound account counter selects to avoid full-history dumps"
```

---

### Task 9: Update Swagger (`MQL5/Libraries/swagger.json`)

**Files:**
- Modify: `MQL5/Libraries/swagger.json`

**Interfaces:**
- Produces: Swagger reflects `/ping`, `/deals` & `/history` query params, wrapped `total`
  schemas, extended Deal/Order/Position/Symbol fields, reason/entry enums. Live-served from disk.

- [ ] **Step 1: Add `/ping` path**

Add a `"/ping"` GET path (tag `account`) with `summary:"ping liveness"`, `operationId:"ping"`,
response 200 referencing a new `Ping` definition.

- [ ] **Step 2: Add query params to `/deals` and `/history`**

For `GET /deals`, add `parameters` including `offset` (int32, default 0), `limit` (int32,
default 100), `position_id` (int64, optional), `symbol` (string, optional), `from`
(string, optional), `to` (string, optional). Mirror the same for `GET /history`.

- [ ] **Step 3: Add wrapped response schemas**

Update `GET /deals` 200 schema to `#/definitions/DealList` = `{type:object, properties:{
  deals: {type:array, items:{$ref:"#/definitions/DealsItem"}}, total: {type:integer, format:int64}
}}`. Update `GET /history` 200 schema to `#/definitions/OrderList` similarly with `orders`.

- [ ] **Step 4: Extend item schemas**

Extend `DealsItem` with `swap`, `entry`, `reason`, `comment`; extend the history `Order`
item with `fill`, `type_filling`, `time_expiration`, `reason`, `comment`; extend `PositionItem`
with `profit`, `swap`, `comment`; extend `Symbol` with the new spec fields from Task 6.
Add `DealReason`/`DealEntry` enum-style definitions (`x-enumNames`) if the file already uses
definitions; otherwise document readable strings in the schema `description`.

- [ ] **Step 5: Add `Ping` definition**

`Ping` = `{type:object, properties:{ pong:{type:boolean}, time:{type:string},
timestamp:{type:integer,format:int64}, terminal_build:{type:integer},
deals_total:{type:integer}, orders_total:{type:integer}, positions_total:{type:integer},
server:{type:string}, account:{type:integer,format:int64}, version:{type:string} }}`.

- [ ] **Step 6: Validate JSON + serve**

Run `node -e "JSON.parse(require('fs').readFileSync('MQL5/Libraries/swagger.json','utf8')); console.log('valid')"`
(or equivalent) to confirm valid JSON. Then (user-side) hit the live `/` to confirm the new
paths render.

- [ ] **Step 7: README note for bounded counters**

Append to `README.md` a note that `/info` & `/balance` `orders_total`/`deal_total` are
last-1-day counts, and that `/deals` & `/history` now wrap results with `total`.

- [ ] **Step 8: Commit**

```bash
git add MQL5/Libraries/swagger.json README.md MQL5/Include/RestApi.mqh
git commit -m "docs(swagger): add /ping, /deals & /history params and total wrappers, extend schemas"
```

---

## Post-Implementation

- Recompile `RestApi.mq5` in MetaEditor (user-side) to produce `.ex5`. Hand back sources + fresh
  `.ex5` + updated `swagger.json` + live verification of the 8 acceptance criteria.
- Live verification checklist (from spec §6): run against live host, confirm tickets, paging/
  dedup, position_id deals with reasons, history filters + nonzero fill, position profit,
  symbol specs, `/ping` latency during heavy dumps, Swagger match.
