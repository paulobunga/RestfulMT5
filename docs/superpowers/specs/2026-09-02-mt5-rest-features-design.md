# MT5 REST Bridge — Production Feature Set (Design)

**Date:** 2026-09-02
**Status:** Approved (brainstorm HARD-GATE passed)
**Scope:** MQL5-only (`MQL5/Include/RestApi.mqh`) + Swagger (`MQL5/Libraries/swagger.json`). **No C++ DLL change or rebuild.**

---

## 1. Context

The MT5 REST bridge (live host `http://169.58.126.101:6542`, live client `ExnessTrader`,
account 476482605/UGX) is hardened and feature-complete. This task adds 8 user-requested
production features to make the API genuinely usable by the live trading client:

1. `/trade` returns **real deal/order/position tickets** (not just retcode).
2. `/deals` gets **correct pagination**, `position_id`/`symbol`/`from`/`to` filters, and **real
   exit reasons** (SL / TP / StopOut / Client / Expert …).
3. `/history` gets **filters** + real fill prices.
4. `/positions` exposes floating **profit / swap / comment**.
5. `/symbols` returns the **full symbol spec**, and `/symbols` (list) is more useful.
6. New **`/ping`** liveness endpoint.
7. **Server stability**: bounded windows, capped pages, per-command timing with
   `Print` warnings, no hung/blocking handlers.
8. **Swagger** updated to match the new schemas/endpoints (served live from disk).

### Constraints (from hardening, still binding)
- HTTP contract unchanged where possible: JSON, camelCase fields, `Authorization` header,
  base path `/` unchanged.
- Changes must be **purely additive** to existing endpoints: existing fields keep their
  names and meaning. No field removed or renamed.
- Command envelope: `{"version":"1","request_id":"<uuid>","command":"<action>",...}`;
  `GetCommand` buffer fixed at 8048 bytes, C++ caps command ~7000 bytes (413).
- Encoding of edited files: `RestApi.mq5` is UTF-16 LE; `RestApi.mqh` is UTF-8 no BOM;
  `swagger.json` is UTF-8. Edit tools corrupt the UTF-16 files — use PowerShell
  `-Encoding Unicode`/`-Encoding UTF8` as appropriate.
- Working tree is `main`, previous hardening work already committed and pushed.

---

## 2. Why no C++ change is needed

Two verified facts from the current C++ (`mt5-rest/microsvc_controller.cpp`, committed `54b99c2`):

- **Query params already flow to MQL5** (lines 350-352): `handleGet` iterates every URL
  query param and adds it to the command JSON as a string value:
  `result[it->first] = web::json::value::string(it->second);`
  So `GET /deals?position_id=123&offset=0&limit=100&from=...&to=...` produces a command with
  `"position_id":"123","offset":"0","limit":"100","from":"...","to":"..."`. MQL5 reads them via
  `CJAVal` accessors (`dataObject["offset"].ToInt()` already works on string values — the
  existing `/deals?offset&limit` path relies on this).

- **Swagger is served live from disk** (lines 302-318): `handleGet` for `/` reads
  `MQL5/Libraries/swagger.json` from disk on every request. Updating the file is enough; it is
  picked up immediately without a rebuild.

Therefore all 8 features are achievable by editing `RestApi.mqh` and `swagger.json` only.

---

## 3. Query parameter parsing convention

Because query params reach MQL5 as **strings**, all new optional parameters must be parsed
defensively from `CJAVal`:

- `offset`/`limit` → `(int)v.ToInt()` with bounds clamping. `offset >= 0`; `limit` default
  **100**, clamp `1..500`.
- `position_id` → `(ulong)v.ToInt()` (0 = no filter).
- `symbol` → `v.ToStr()`, empty = no filter.
- `from`/`to` → flexible timestamp parser: accept (a) an integer epoch in **seconds**
  (13-digit → divide by 1000 = millis→seconds, 10-digit = seconds), or (b) an ISO-8601
  string via `StringToTime()`. Helper `datetime parseFromParam(string) / parseToParam(string)`.
  `from` default `0`, `to` default `TimeCurrent()`.

---

## 4. Detailed design per requirement

### 4.1 `/trade` — real tickets in the response (`orderDoneOrError`, `tradingModule`)

Current `orderDoneOrError(bool error, string funcName, CTrade &trade)` returns only
`{error, description, order_id, volume, price, bid, ask, function}` and uses
`trade.ResultOrder()`, `trade.ResultVolume()`, `trade.ResultPrice()`.

**New behavior** — build the response directly from the real `MqlTradeResult` via
`trade.Result()` and add the position id:

```
conf["retcode"]        = (int)r.retcode
conf["retcode_external"] = (int)r.retcode_external
conf["order_id"]       = (ulong)r.order          // real order ticket
conf["deal_id"]        = (ulong)r.deal           // real deal ticket (0 if none)
conf["position_id"]    = position id (best-effort)
conf["symbol"]         = symbol used
conf["type"]           = EnumToString(order type)
conf["price"]          = r.price                  // real fill price
conf["volume"]         = r.volume                 // real filled volume
conf["bid"]            = r.bid
conf["ask"]            = r.ask
conf["time"]           = fromDateTime(TimeTradeServer())
conf["error"]          = (int)r.retcode           // kept for backward compat
conf["description"]    = GetRetcodeID(r.retcode)
conf["function"]       = funcName
```

**Best-effort `position_id`** — after a successful order that opened a position
(market `BUY`/`SELL`), read it from the resulting deal:
`HistoryDealGetInteger(r.deal, DEAL_POSITION_ID)` if `r.deal > 0` and the deal resolves;
otherwise scan open positions for `symbol` and set `POSITION_IDENTIFIER`; otherwise `0`.
For close/modify/delete (no new position) `position_id` is `0` — "where valid" per the
requirement.

**Interface change:** `orderDoneOrError` signature needs the symbol and order type to fill
`symbol`/`type`. The trade path is the only caller. Keep backward compatibility by adding
optional params `string pSymbol=""` and `string pType=""` (default empty → fields set to
empty/0 when not provided).

### 4.2 `/deals` — pagination, filters, reasons (`getTransactions`)

Current `getTransactions(CJAVal &dataObject)` is buggy: `limit==0` → full dump; off-by-one
wrapping at each end; no filters; no reasons; returns a bare array.

**New behavior** — full rewrite of the body (signature unchanged: `getTransactions(CJAVal&)`):

1. Parse `offset`, `limit` (default 100, clamp 1..500), optional `position_id`, `symbol`,
   `from`, `to` (parse convention §3).
2. `HistorySelect(from, to)` — **bounded window**, never `HistorySelect(0,TimeCurrent())`.
3. Walk `HistoryDealsTotal()` once, collecting tickets that match `position_id` and/or
   `symbol` into a dynamic array of `ulong`.
4. `total = collected.Count()`; page slice `[offset, min(offset+limit, total))` from the
   collected array (newest-first: iterate deals from `HistoryDealsTotal()-1` down so index 0
   of the collected array is the newest; page preserves that ordering).
5. For each paged deal build the object:
   ```
   id, time, symbol, type, type_str?, volume, price, commission, swap?,
   profit, position_id, order_id, entry, reason, comment, external_id?
   ```
   - `reason`: readable string via `ENUM_DEAL_REASON` mapping: `DEAL_REASON_CLIENT`→"client",
     `DEAL_REASON_EXPERT`→"expert", `DEAL_REASON_DEALER`→"dealer",
     `DEAL_REASON_SL`→"stop loss", `DEAL_REASON_TP`→"take profit", `DEAL_REASON_SO`→"stop out",
     `DEAL_REASON_ROLLOVER`→"rollover", `DEAL_REASON_EXTERNAL`→"external",
     `DEAL_REASON_VMARGIN`→"variation margin", `DEAL_REASON_SPLIT`→"split",
     default `EnumToString`.
   - `entry`: readable via `ENUM_DEAL_ENTRY`: `DEAL_ENTRY_IN`→"in", `DEAL_ENTRY_OUT`→"out",
     `DEAL_ENTRY_INOUT`→"inout", `DEAL_ENTRY_OUT_BY`→"out_by", default `EnumToString`.
   - `swap`: `HistoryDealGetDouble(ticket, DEAL_SWAP)`.
   - `comment`: `HistoryDealGetString(ticket, DEAL_COMMENT)`.
   - existing `id/price/commission/time/symbol/type/profit/volume/position_id/order_id` kept.
6. Wrap: `{"deals":[ ... ], "total": <ulong>}`. Empty page → `{"deals":[], "total":N}` so the
   client stops when `deals.length < limit`.
7. `if(debug) Print(t)` preserved.

**Reason enum mapping** is read from `ENUM_DEAL_REASON` index. Note option values can exceed
the classic list on some brokers; the fallback `EnumToString` guarantees a non-empty string.

### 4.3 `/history` — filters + real fill price (`getOrdersHistory`)

Current `getOrdersHistory()` takes **no params**, does `HistorySelect(0,TimeCurrent())`, returns
a bare array, and `open = ORDER_PRICE_OPEN` (the order's limit/open price, **not** the fill).

**New behavior** — signature changes to `getOrdersHistory(CJAVal &dataObject)` so filters flow
in. Dispatch line 192 updates to `getOrdersHistory(jCommand)`.

1. Parse `offset`, `limit` (default 100, clamp 1..500), optional `position_id`, `symbol`,
   `from`, `to`.
2. `HistorySelect(from, to)` — bounded.
3. Walk `HistoryOrdersTotal()`, collect tickets matching `position_id` (`ORDER_POSITION_ID`)
   and/or `symbol`. `total = collected.Count()`; page slice `[offset, offset+limit)` newest-first.
4. Each order object adds/changes:
   - **`fill`**: for a filled order, `HistoryOrderGetDouble(ticket, ORDER_PRICE_CURRENT)` is the
     fill price. When `ORDER_STATE == ORDER_STATE_FILLED`, `fill = ORDER_PRICE_CURRENT`;
     otherwise `fill = 0`. (Additive new field; `open` keeps `ORDER_PRICE_OPEN`.)
   - Add `type_filling` (`EnumToString(ENUM_ORDER_TYPE_FILLING(...))`), `comment`,
     `time_expiration`, `reason` (readable `ENUM_ORDER_REASON` mapping like deals).
   - Keep existing: `id, open, symbol, state, magic, type, time_setup, time_done, stoploss,
     takeprofit, volume, position_id`.
5. Wrap: `{"orders":[ ... ], "total": N}`.

### 4.4 `/positions` — profit, swap, comment (`getPositions`)

Current `getPositions()` returns a bare array with `id, magic, symbol, type, time_setup, open,
stoploss, takeprofit, volume, price_current`.

**Additive change** — add three fields per position (keep array shape; `/positions` is a list
that clients already consume, wrapping would be a breaking change and the user did not request
a `total` here):
```
profit  = PositionGetDouble(POSITION_PROFIT)
swap    = PositionGetDouble(POSITION_SWAP)
comment = PositionGetString(POSITION_COMMENT)
```
(Note: user's wrapped-object decision applied to `/deals` and `/history` which paginate and were
asked for `total`; `/positions` was not — keep bare array.)

### 4.5 `/symbols` — full spec + list (`getSymbols`, `getSymbolInfoFull`)

**`/symbols` (list, `getSymbols`)** — currently only `{"name": "..."}` per item. Extend each
list item (lightweight, additive) with:
```
name, digits, point, spread, min_volume, max_volume, volume_step,
trade_mode (readable), trade_exemode (readable), session_open, session_close
```
Readable via `SymbolInfo*` with `SymbolName(i,false)` selected. Guard each `SymbolInfo*` call
with `SymbolSelect(name,true)` first where required.

**`/symbols/{name}` (`getSymbolInfoFull`)** — already returns ~20 fields. Add (pure additions):
```
point, ticks_book_depth, margin_currency, profit_currency, trade_currency,
base_currency, quote_currency, trade_calc_mode(readable),
stops_level(trade_stops_level present), freeze_level(present),
swap_mode, swap_type, swap_rollover3days, trade_time, trade_stops_level(present),
expiration_mode, volume_limit, volume_min(present), volume_max(present),
volume_step(present), value_tick? (tick_value present), margin_initial, margin_maintenance
```
Keep all existing fields unchanged.

### 4.6 `/ping` — new liveness endpoint

New action + handler `getPing()`:
```
{
  "pong": true,
  "time":     fromDateTime(TimeTradeServer()),
  "timestamp": (ulong)TimeCurrent(),
  "terminal_build": (int)TerminalInfoInteger(TERMINAL_BUILD),
  "deals_total":    HistorySelect(0,TimeCurrent()) ? HistoryDealsTotal() : 0,
  "orders_total":   HistoryDealsTotal()-? no -> use HistoryOrdersTotal via same select,
  "positions_total": PositionsTotal(),
  "server":    AccountInfoString(ACCOUNT_SERVER),
  "account":   (ulong)AccountInfoInteger(ACCOUNT_LOGIN),
  "version":   "1"
}
```
**Dispatch** (add near the other actions): `if(action == "ping") { response = getPing(); }`.

`/ping` stays light: one `HistorySelect(0,TimeCurrent())` for two counters and no record dumps,
so it returns almost instantly even though it is a normal queued command.

### 4.7 Server stability (cross-cutting)

1. **Bounded `HistorySelect`**: all history/deals/orders handlers now use the `from`/`to`
   window from §3 instead of `HistorySelect(0, TimeCurrent())`. Large dumps are capped by
   `limit` ≤ 500.
2. **Per-command elapsed timing** in `Processing()`: record `GetTickCount64()` before dispatch
   and after `SetCommandResponse`; if elapsed > 3000 ms, `Print("REST: slow command ... N ms")`.
   Light, debug-free, always-on.
3. **All handlers return JSON**: the existing fallback (`if(StringLen(response) < 1)
   response = notImpemented(action);`) stays, so no call can leave the reply empty / hang the
   client's `waitForCommandResponse` into a 504.
4. **Documented limitation**: MQL5 `OnTimer` processes one queued command per tick, so a single
   long-running handler cannot be preempted. With bounded windows and capped pages each command
   completes in ~tens of ms, keeping `/ping` latency low. True preemption would require moving
   history iteration to C++ (out of scope). This limitation is stated explicitly here and in the
   plan.
5. **No changes to `Print` debug-gating** (existing `if(debug) Print(t)` stays).

---

## 5. Files touched

| File | Change |
|------|--------|
| `MQL5/Include/RestApi.mqh` | Rewrite `getTransactions`, `getOrdersHistory`, `orderDoneOrError`; extend `getPositions`, `getSymbols`, `getSymbolInfoFull`; add `getPing`, `parseFromParam`, `parseToParam`, `dealReasonString`, `dealEntryString`, `orderReasonString`; add `ping` dispatch; per-command elapsed `Print`; update history dispatch arg |
| `MQL5/Libraries/swagger.json` | Add `/ping`; add query params to `/deals` & `/history`; add wrapped response schemas (`DealList`/`OrderList` with `total`); extend `Deal`/`Order`/`Position`/`Symbol` schemas; add enums |

No C++ files change. No `.ex5` recompile by us (handled separately by the user; we provide
sources + updated Swagger + instructions).

---

## 6. Definition of done (acceptance)

Run against live host and confirm all 8:
1. `/trade` returns real `order_id`, `deal_id`, `position_id` (where valid), `symbol`, `type`,
   fill `price`, `volume`, `retcode`, `retcode_external`, `time`.
2. `/deals` pages correctly (`total` + slice), returns exactly ≤ `limit` records; filters by
   `position_id`/`symbol`; `reason` shows real exit (SL/TP/StopOut/...) and `entry` in/out.
3. `/history` filters by `position_id`/`symbol`/`from`/`to` and `fill` is non-zero for filled
   orders.
4. `/positions` includes per-position `profit`, `swap`, `comment`.
5. `/symbols` returns list with useful spec; `/symbols/{name}` returns expanded spec.
6. `/ping` returns `{pong:true, ...}` with counters even while repeated `/history`/`/deals`
   dumps run; latency stays low.
7. No hung commands / repeated 504s; slow commands surface a `Print` warning.
8. Swagger UI reflects `/ping`, new params, wrapped schemas, extended fields.
