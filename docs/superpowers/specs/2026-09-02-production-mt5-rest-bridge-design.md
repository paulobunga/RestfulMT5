# Production-Ready MT5 REST Bridge — Design

**Date:** 2026-09-02
**Status:** Approved

## Context

`mt5-rest-api` turns MetaTrader 5 into a REST API server for algorithmic
trading. The C++ DLL (`mt5-rest.dll`, built with cpprestsdk) hosts an HTTP
server, and the MQL5 EA (`RestApi.mq5` + `RestApi.mqh`) processes commands and
returns responses. Communication is a command-queue pattern: the C++ side
serializes each HTTP request into a JSON command pushed into a `SafeVector`;
MQL5's `OnTimer` polls `GetCommand`, processes it, and calls
`SetCommandResponse` which stores the result in a `SafeMap`; the C++ HTTP
handler busy-waits polling that map for the answer.

The current implementation is not production-safe. This spec hardens the
core infrastructure, fixes concurrency bugs, adds missing MT5 coverage, and
adds production operational endpoints.

## Goals

1. Eliminate all data races and busy-wait CPU burn.
2. Add full MT5 account/symbol/tick/portfolio coverage.
3. Add production trading actions (close all, close by symbol, batch).
4. Add operational endpoints (`/health`, `/version`) and request logging.
5. Fix CORS, HTTP method handling, and structured error responses.
6. Keep the existing EA public interface so `RestApi.mq5` works unmodified.

## Non-Goals (explicitly out of scope for now)

- HTTPS / TLS support (plain HTTP on a trusted host is acceptable).
- Multi-user authentication or per-user tokens.
- Rate limiting (deferred; queue bound covers memory safety).

## Architecture

The command-queue pattern is retained but hardened. Both layers (C++ and
MQL5) are changed; they are coupled by the JSON command envelope, so the
envelope is versioned and carries a `request_id` for robust matching.

### Command Envelope (shared contract)

Every command pushed to the queue is a JSON object:

```json
{
  "version": "1",
  "request_id": "<uuid>",
  "command": "<action>",
  "id": "<optional path id>",
  ...query/body params...
}
```

The MQL5 side echoes the exact command string back in `SetCommandResponse`;
the C++ waiter matches on the full command string (as today) but now waits on
a condition variable instead of polling.

## Section 1 — Core Infrastructure (C++)

### 1a. Thread-safe containers

`SafeMap` and `SafeVector` are rewritten so **every** public method acquires
the mutex:

- `SafeMap`: `add`, `remove`, `contains`, `operator[]` all lock. A
  `try_get(key, value&)` helper is added for atomic read-and-erase.
- `SafeVector`: `push_back`, `pop_back`, `size`, `back`, `operator[]`,
  `begin`, `end` all lock. Add `front()` (safe single-consumer pop).

### 1b. Blocking wait (replace busy-poll)

`SafeMap` gains a `std::condition_variable` associated with its mutex.
The HTTP waiter calls `wait_for_response(command, timeout_ms)` which waits on
the condition variable and returns true when the response appears or false on
timeout. `setCommandResponse` notifies after inserting. This removes the
`Sleep(1)` loops in `handleGet`/`handlePost`.

### 1c. Bounded command queue

`SafeVector` (the outbound command queue) is bounded at a configurable max
(default 256). `push_back` returns false when full. HTTP handlers return
HTTP 503 when the queue is full instead of growing unboundedly.

### 1d. Version + request_id

`MicroserviceController::handleGet` and `handlePost` build the command
envelope with `"version":"1"` and a fresh `request_id` (generated via a small
UUID helper or counter + timestamp). The command string (including
`request_id`) is the matching key.

## Section 2 — HTTP Handling (C++)

### 2a. CORS on all responses

Add helper `applyCorsHeaders(http_response&)` that sets
`Access-Control-Allow-Origin: *`, `-Methods`, `-Headers` on **every**
response, not just OPTIONS.

### 2b. Method handlers

- `handleDelete`: implement — process `/orders/{id}` and `/positions/{id}`
  as delete commands through the queue (e.g. `order_delete`, `position_delete`).
- `handlePut`/`handlePatch`: route through the queue for modify operations
  instead of always returning NotImplemented; fix the enum reference
  (`methods::PUT`/`methods::PATCH` instead of `methods::MERGE`).
- `serviceName` in `responseNotImpl` corrected to "MT5 REST".

### 2c. Structured errors

Unify error JSON shape:

```json
{ "code": <int>, "message": "<string>", "request_id": "<uuid>" }
```

with correct HTTP status codes and `Content-Type: application/json` on all
error responses. Map:
- 400 — malformed JSON / missing required field
- 401 — missing/wrong auth token
- 404 — unknown path / resource not found
- 409 — trade/action rejected
- 429 — queue full (temporarily)
- 500 — internal/unhandled
- 503 — server busy / queue full

### 2d. Health & version (C++-only, no MQL5 hop)

- `GET /health` → `{ "status":"ok", "uptime_sec":N, "version":"1", "mql5_connected":bool, "queue_depth":N }`
  `mql5_connected` tracks whether any response has been received from the EA
  (a heartbeat flag set by `setCommandResponse`).
- `GET /version` → `{ "name":"mt5-rest", "version":"1.0.0", "protocol":"1" }`

These are handled entirely in C++ before token/trade processing, so they work
even if the MQL5 side is down.

### 2e. Request logging

Each handled request logs `method path status duration_ms` via the existing
`writeLog` facility and to stderr via `ucout`. Toggleable via a flag.

## Section 3 — Missing Endpoints (MQL5)

New actions handled in the recreated `RestApi.mqh`:

| Endpoint | Action | Description |
|----------|--------|-------------|
| `GET /account` | `account` | Full account properties (company, currency, server, leverage, balance, equity, margin, margin_free, margin_level, profit, credit, type, name, number, trade_mode, limit_orders, margin_so_mode, trade_allowed, trade_expert, hedging, fifo, stopout_level, stopout_mode) |
| `GET /symbols` | `symbols` (no id) | List all symbol names from `SymbolsTotal()` |
| `GET /symbols/{name}` | `symbols` | Enhanced: existing fields + session open/close, spread, swap_long, swap_short, digits, fill_mode, execution_mode, expiration mode |
| `GET /tick/{symbol}` | `tick` | Latest tick: bid, ask, last, volume, time_flags, time |
| `GET /positions/pnl` | `positions_pnl` | Sum of floating profit; aggregate per symbol |
| `GET /margin/{symbol}` | `margin` | Margin calculation for an order (OrderCalcMargin) |
| `GET /account/history` | `account_history` | Equity/deposit/withdrawal history for a date range |
| `POST /trade/close_all` | `trade_close_all` | Close all open positions |
| `POST /trade/close_symbol` | `trade_close_symbol` | Close all positions of a symbol |
| `POST /trade/batch` | `trade_batch` | Execute an array of trade actions in one request |

New private MQL5 methods: `getAccount()`, `getSymbols()`,
`getSymbolInfoFull(name)`, `getTick(symbol)`, `getPositionsPnl()`,
`getMargin(symbol)`, `getAccountHistory()`, `tradeCloseAll()`,
`tradeCloseSymbol(symbol)`, `tradeBatch(dataObject)`. Plus a `fromTimeRange`
helper and existing `StringToTimeframe` reuse.

## Section 4 — MQL5 Recreate

`RestApi.mqh` is recreated as a UTF-8 file. It preserves the public
interface (`Init`, `SetAuth`, `Processing`, `OnTradeTransaction`, `Pub`,
`SetCallback`) and adds the handlers above. The `Processing` loop's action
if-chain is extended. The `root` dispatch also supports the new `symbols`
(no-id), `account`, `tick`, `margin`, `positions_pnl`, `account_history`
actions, and passes the full command object to `tradingModule` for
`close_all`/`close_symbol`/`batch` variants.

## Section 5 — Build & Docs

- `mt5-rest.vcxproj` may need the new source files (none added — all changes
  in existing files; no project change expected).
- README updated with all new endpoints and the `batch` trade format.

## File Change Summary

| File | Change |
|------|--------|
| `mt5-rest/safe_map.hpp/.cpp` | Full locking; condition_variable wait; try_get |
| `mt5-rest/safe_vector.hpp/.cpp` | Full locking; bounded queue; front() |
| `mt5-rest/microsvc_controller.hpp/.cpp` | CORS, DELETE/PUT/PATCH, structured errors, /health, /version, logging, request_id, queue bound, wait_for |
| `mt5-rest/main.cpp` | Expose mql5_connected heartbeat; pass version info |
| `MQL5/Include/RestApi.mqh` | Recreate as UTF-8 with all new handlers |
| `README.md` | New endpoints + batch format |

## Verification

- DLL builds in Visual Studio 2017+ (x64, Release); EA compiles in MT5 (F7).
- Endpoints return correct JSON against a live/practice account.
- Concurrent requests complete without crash (thread-safety).
- No busy-wait: process CPU near idle when no requests pending.
- `/health` and `/version` respond even when MQL5 is not connected.
