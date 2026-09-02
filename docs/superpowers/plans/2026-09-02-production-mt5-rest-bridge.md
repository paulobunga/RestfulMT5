# Production MT5 REST Bridge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the MT5 REST bridge production-safe: fix thread-safety bugs, eliminate busy-wait CPU burn, add full MT5 account/symbol/tick/portfolio coverage, add batch/close-all trading, and add operational endpoints with logging.

**Architecture:** Harden the existing command-queue pattern. Fix `SafeMap`/`SafeVector` concurrency, replace `Sleep(1)` polling with a `condition_variable` wait, bound the queue, add a versioned command envelope with `request_id`, add CORS/structured errors, and extend the MQL5 `RestApi.mqh` handler with new actions. The MQL5 file is recreated as UTF-8.

**Tech Stack:** C++ (cpprestsdk, boost), MQL5, Visual Studio 2017+ x64, MetaTrader 5.

**Spec:** `docs/superpowers/specs/2026-09-02-production-mt5-rest-bridge-design.md`

## Global Constraints

- Plain HTTP only (no TLS) — per user approval.
- `/trade/batch` is required — per user approval.
- All changes to existing files; no new `.cpp`/`.hpp` files expected (vcxproj untouched unless a build error requires it).
- **`GetCommand` buffer limit:** The MQL5 EA reads commands into a fixed `uchar _command[8048]` buffer and `main.cpp` copies with `strcpy`. Command JSON must stay well under 8048 bytes. The batch payload is the main overflow risk — the MQL5 side must bound the number of batch operations it accepts (cap at 20) and the C++ side must reject requests whose serialized command would exceed a safe limit (~7000 bytes) with HTTP 413.
- MQL5 `RestApi.mqh` must preserve the public interface: `Init`, `SetAuth`, `Processing`, `OnTradeTransaction`, `Pub`, `SetCallback` — so `RestApi.mq5` works unmodified.
- Existing UTC ISO-8601 datetime helper `fromDateTime` is reused; do not re-implement.
- All new error responses use the unified shape `{ "code", "message", "request_id" }` with `Content-Type: application/json`.

---

### Task 1: Harden SafeMap (thread-safety + blocking wait)

**Files:**
- Modify: `mt5-rest/safe_map.hpp`
- Modify: `mt5-rest/safe_map.cpp`

**Interfaces:**
- Consumes: existing `SafeMap` public methods.
- Produces:
  - `void add(string key, string value)` — locks, inserts, notifies.
  - `bool contains(string key)` — locks, returns presence.
  - `void remove(string key)` — locks, erases.
  - `bool try_get(const string& key, string& value)` — atomically reads and erases; returns true if key existed. **New.**
  - `bool wait_for(const string& key, string& value, int timeout_ms)` — blocks on the condition variable until the key appears (or timeout); on success extracts+erases into `value` and returns true; on timeout returns false. **New.**

- [ ] **Step 1: Rewrite `safe_map.hpp`**

Replace `safe_map.hpp` with:

```cpp
#ifndef SAFEMAP_HPP
#define SAFEMAP_HPP

#include <map>
#include <mutex>
#include <condition_variable>
#include <string>

using namespace std;

class SafeMap {
public:
	SafeMap() : data(), mut(), cond() {}
	SafeMap(const SafeMap& orig) : data(orig.data), mut(), cond() {}
	~SafeMap() {}

	void add(string key, string value);
	bool contains(string key);
	void remove(string key);
	bool try_get(const string &key, string &value);
	bool wait_for(const string &key, string &value, int timeout_ms);

private:
	map<string,string> data;
	mutable mutex mut;
	condition_variable cond;
};

#endif /* SAFEMAP_HPP */
```

- [ ] **Step 2: Rewrite `safe_map.cpp`**

Replace `safe_map.cpp` with:

```cpp
#include "stdafx.h"
#include <string>
#include <utility>
#include <chrono>
#include "safe_map.hpp"

void SafeMap::add(string key, string value) {
	lock_guard<mutex> lock(mut);
	data[key] = move(value);
	cond.notify_all();
}

bool SafeMap::contains(string key) {
	lock_guard<mutex> lock(mut);
	return data.count(key) > 0;
}

void SafeMap::remove(string key) {
	lock_guard<mutex> lock(mut);
	data.erase(key);
	cond.notify_all();
}

bool SafeMap::try_get(const string &key, string &value) {
	lock_guard<mutex> lock(mut);
	auto it = data.find(key);
	if (it == data.end())
		return false;
	value = it->second;
	data.erase(it);
	cond.notify_all();
	return true;
}

bool SafeMap::wait_for(const string &key, string &value, int timeout_ms) {
	unique_lock<mutex> lock(mut);
	auto pred = [&]() { return data.count(key) > 0; };
	bool found = cond.wait_for(lock, chrono::milliseconds(timeout_ms), pred);
	if (found) {
		value = data[key];
		data.erase(key);
		cond.notify_all();
	}
	return found;
}
```

Note: `mut` is now `mutable` because `wait_for`/`contains` may be called on what the old code treated as logically-const paths.

- [ ] **Step 3: Commit**

```bash
git add mt5-rest/safe_map.hpp mt5-rest/safe_map.cpp
git commit -m "fix(safe_map): full locking and condition-variable wait"
```

---

### Task 2: Harden SafeVector (thread-safety + bounded queue)

**Files:**
- Modify: `mt5-rest/safe_vector.hpp`
- Modify: `mt5-rest/safe_vector.cpp`

**Interfaces:**
- Consumes: existing `SafeVector` usage in `microsvc_controller.cpp`.
- Produces:
  - `bool push_back(string in)` — locks, pushes if under `max_size_`, returns true on success, false when full. **Signature changes from void → bool.**
  - `size_t size()` — locks.
  - `string front()` — locks, returns first element (peek, no pop) with bounds check (returns empty string if empty).
  - `string pop_front()` — locks, removes and returns first element; returns empty string if empty. **New.**
  - `void set_max_size(size_t n)` — sets the bound (0 = unbounded, default 256).
  - Existing `insert`, `pop_back`, `back`, `operator[]`, `begin`, `end`, `toVector` retained but now lock where they read/write shared state.

- [ ] **Step 1: Rewrite `safe_vector.hpp`**

Replace `safe_vector.hpp` with:

```cpp
#ifndef SAFEVECTOR_HPP
#define SAFEVECTOR_HPP

#include <vector>
#include <mutex>
#include <condition_variable>
#include <string>
using namespace std;

class SafeVector {
public:
	SafeVector() : vec(), mut(), cond(), max_size_(256), use_bound_(false) {}
	SafeVector(const SafeVector& orig) : vec(orig.vec), mut(), cond(),
		max_size_(orig.max_size_), use_bound_(orig.use_bound_) {}
	~SafeVector() {}

	void set_max_size(size_t n);
	bool push_back(string in);
	string pop_front();
	string front();
	size_t size();
	string& operator[](const int index);
	vector<string> toVector();

private:
	vector<string> vec;
	mutable mutex mut;
	condition_variable cond;
	size_t max_size_;
	bool use_bound_;
};
```

(Removed the unsafe `begin`/`end`/`back`/`insert`/`pop_back` free iterators — `microsvc_controller.cpp` is updated in Task 4 to use `pop_front`/`front`/`size`.)

- [ ] **Step 2: Rewrite `safe_vector.cpp`**

Replace `safe_vector.cpp` with:

```cpp
#include "stdafx.h"
#include <string>
#include <utility>
#include "safe_vector.hpp"

void SafeVector::set_max_size(size_t n) {
	lock_guard<mutex> lock(mut);
	max_size_ = n;
	use_bound_ = (n > 0);
}

bool SafeVector::push_back(string in) {
	lock_guard<mutex> lock(mut);
	if (use_bound_ && vec.size() >= max_size_)
		return false;
	vec.push_back(move(in));
	cond.notify_one();
	return true;
}

string SafeVector::pop_front() {
	lock_guard<mutex> lock(mut);
	if (vec.empty())
		return string();
	string out = move(vec.front());
	vec.erase(vec.begin());
	cond.notify_one();
	return out;
}

string SafeVector::front() {
	lock_guard<mutex> lock(mut);
	if (vec.empty())
		return string();
	return vec.front();
}

size_t SafeVector::size() {
	lock_guard<mutex> lock(mut);
	return vec.size();
}

string& SafeVector::operator[](const int index) {
	lock_guard<mutex> lock(mut);
	return vec[index];
}

vector<string> SafeVector::toVector() {
	lock_guard<mutex> lock(mut);
	return vec;
}
```

- [ ] **Step 3: Commit**

```bash
git add mt5-rest/safe_vector.hpp mt5-rest/safe_vector.cpp
git commit -m "fix(safe_vector): full locking and bounded queue"
```

---

### Task 3: Add UUID/request_id + version helpers in C++

**Files:**
- Modify: `mt5-rest/microsvc_controller.hpp`
- Modify: `mt5-rest/microsvc_controller.cpp`

**Interfaces:**
- Consumes: `SafeMap::wait_for`, `SafeVector::push_back`.
- Produces:
  - `static utility::string_t makeRequestId();` — returns a short unique id string (timestamp-ms + counter), e.g. `U("1617200000000-42")`.
  - `static const string_t& protocolVersion();` — returns `U("1")`.

- [ ] **Step 1: Add declarations to `microsvc_controller.hpp`**

Add private static members to `MicroserviceController`:

```cpp
private:
	static json::value responseNotImpl(const http::method & method);
	static utility::string_t makeRequestId();
	static const utility::string_t protocolVersion();
```

- [ ] **Step 2: Add definitions to `microsvc_controller.cpp`**

Add near the top of `microsvc_controller.cpp` (after includes/defines):

```cpp
static long long g_counter = 0;
static std::mutex g_counter_mutex;

utility::string_t MicroserviceController::makeRequestId() {
	std::lock_guard<std::mutex> lock(g_counter_mutex);
	g_counter++;
	SYSTEMTIME st;
	GetLocalTime(&st);
	wchar_t buf[64];
	swprintf_s(buf, 64, L"%04d%02d%02d%02d%02d%02d%03d-%lld",
		st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond,
		st.wMilliseconds, g_counter);
	return utility::string_t(buf);
}

const utility::string_t MicroserviceController::protocolVersion() {
	return U("1");
}
```

- [ ] **Step 3: Commit**

```bash
git add mt5-rest/microsvc_controller.hpp mt5-rest/microsvc_controller.cpp
git commit -m "feat(controller): request_id and protocol version helpers"
```

---

### Task 4: Rewrite MicroserviceController HTTP handling

**Files:**
- Modify: `mt5-rest/microsvc_controller.hpp`
- Modify: `mt5-rest/microsvc_controller.cpp`
- Modify: `mt5-rest/main.cpp`

**Interfaces:**
- Consumes: `SafeMap::wait_for`, `SafeVector::push_back`/`front`/`pop_front`/`size`, `makeRequestId`, `protocolVersion`.
- Produces:
  - `bool mql5_connected` private member + `void markMql5Connected()` (called by `setCommandResponse`).
  - `static http_response buildHealthResponse();` and `static http_response buildVersionResponse();`
  - `static void applyCorsHeaders(http_response&);`
  - `http_response formatStructuredError(int http_status, int code, const utility::string_t& message, const utility::string_t& request_id);`
  - `bool enqueueCommand(const utility::string_t& commandJson, http_request& request, const utility::string_t& request_id, bool& too_big);` — enqueues, waits on `wait_for`, replies. Helper used by get/post/delete/put/patch.

- [ ] **Step 1: Update `microsvc_controller.hpp`**

Add members:

```cpp
private:
	bool mql5_connected = false;
	std::mutex mql5_conn_mutex;

	static json::value responseNotImpl(const http::method & method);
	static utility::string_t makeRequestId();
	static const utility::string_t protocolVersion();
	static void applyCorsHeaders(http_response & response);
	static http_response buildHealthResponse(bool mql5_connected, size_t queue_depth, long uptime_sec);
	static http_response buildVersionResponse();
	http_response formatStructuredError(int http_status, int code,
		const utility::string_t & message, const utility::string_t & request_id);
	bool waitForCommandResponse(const string & command, http_request & message,
		const utility::string_t & request_id, bool & timed_out);
	void markMql5Connected();
```

Add a public accessor (used only internally; `setCommandResponse` calls it):

Keep `setCommandResponse` as-is but call `markMql5Connected()` inside its implementation in the `.cpp`.

- [ ] **Step 2: Rewrite `microsvc_controller.cpp`**

This is the largest change. Replace `handleGet`, `handlePost`, `handleDelete`, `handlePut`, `handlePatch`, `handleOptions`, and add the new helpers.

Key changes:

**(a) `setCommandResponse` marks MQL5 connected:**

```cpp
void MicroserviceController::setCommandResponse(const char* command, const char* response) {
	markMql5Connected();
	commandResponses.add(command, response);
}
```

**(b) CORS helper:**

```cpp
void MicroserviceController::applyCorsHeaders(http_response & response) {
	response.headers().add(U("Access-Control-Allow-Origin"), U("*"));
	response.headers().add(U("Access-Control-Allow-Methods"), U("GET, POST, PUT, PATCH, DELETE, OPTIONS"));
	response.headers().add(U("Access-Control-Allow-Headers"), U("Content-Type, Authorization"));
}
```

**(c) Structured error:**

```cpp
http_response MicroserviceController::formatStructuredError(int http_status, int code,
	const utility::string_t & message, const utility::string_t & request_id) {
	web::json::value body = web::json::value::object();
	body[U("code")] = web::json::value::number(code);
	body[U("message")] = web::json::value::string(message);
	body[U("request_id")] = web::json::value::string(request_id);
	http_response response(http_status);
	applyCorsHeaders(response);
	response.headers().add(U("Content-Type"), U("application/json"));
	response.set_body(body);
	return response;
}
```

**(d) `waitForCommandResponse`:** replaces the busy-wait loop in get/post. Returns true if a response was produced (message already replied), or false on timeout (caller replies 504). Enforces the command-size limit (refuse >7000 bytes with 413).

**(e) Rewritten `handleGet`:** applies CORS, handles `/health` and `/version` paths before auth, keeps docs/swagger, keeps auth, builds envelope with request_id + version, enqueues, waits.

**(f) Rewritten `handlePost`:** applies CORS, auth, `/sub` handling, then same envelope path.

**(g) `handleDelete`:** now processes `/orders/{id}` and `/positions/{id}` as `order_delete` / `position_delete` commands through the queue.

**(h) `handlePut` / `handlePatch`:** route through queue for modify operations (`order_modify` / `position_modify`) instead of always NotImplemented; fix enum references to `methods::PUT`/`methods::PATCH`.

**(i) `handleOptions`:** apply CORS + Allow.

**(j) `handleHead`:** return `/version`-style JSON.

- [ ] **Step 3: Add request logging**

Add a private `void logRequest(const http_request&, int status, long long start_ticks)` that writes `method path status duration_ms` to stderr via `ucout` (and optionally the `D:\rest.log` `writeLog` facility already used in `main.cpp`). Call it at the end of each `handleGet`/`handlePost`/`handleDelete`/`handlePut`/`handlePatch` before replying, computing duration from a `GetTickCount64()` captured at handler entry. Use existing `GetTickCount64()` (not the old `GetTickCount()` 32-bit wrapper).

- [ ] **Step 4: Update `main.cpp` to expose the command getter safely**

The current `GetCommand` uses `strcpy`. Replace with a bounded copy using `strncpy_s` and return the command via `pop_front`:

```cpp
MT_EXPFUNC int __stdcall GetCommand(char *data) {
	if (!server.hasCommands())
		return 0;
	string cmd = server.popCommand();  // new helper below
	if (cmd.empty())
		return 0;
	if (cmd.size() + 1 > 8048)
		cmd = cmd.substr(0, 8047);
	strncpy_s(data, 8048, cmd.c_str(), cmd.size());
	return 1;
}
```

Add to `microsvc_controller.hpp` a `string popCommand()` that wraps `commands.pop_front()`, and a `size_t pendingCommands()` that wraps `commands.size()` and updates `hasCommands()` to use it.

- [ ] **Step 5: Commit**

```bash
git add mt5-rest/microsvc_controller.hpp mt5-rest/microsvc_controller.cpp mt5-rest/main.cpp
git commit -m "feat(controller): CORS, structured errors, health/version, DELETE/PUT/PATCH, blocking wait, bounded queue, request logging"
```

---

### Task 5: MQL5 RestApi.mqh — recreate with full coverage

**Files:**
- Delete then recreate: `MQL5/Include/RestApi.mqh` (as UTF-8)

**Interfaces:**
- Consumes: action strings from the C++ envelope (`account`, `symbols`, `tick`, `positions_pnl`, `margin`, `account_history`, `trade_close_all`, `trade_close_symbol`, `trade_batch`, plus existing `info`, `balance`, `positions`, `orders`, `history`, `deals`, `trade`, `candles`).
- Produces: matching JSON responses serialized back via `SetCommandResponse`.

- [ ] **Step 1: Write the full `RestApi.mqh`**

Recreate the file preserving the entire existing public interface and all existing handlers, and add the new private methods and action dispatches. Because the file is large, write it in full — preserving: `#property` header, the `#import "mt5-rest.dll"` block, class `CRestApi` public/private declarations, `Init`, `SetAuth`, `Deinit`, `Processing`, `OnTradeTransaction`, all existing getters, `tradingModule`, `orderDoneOrError`, `actionDoneOrError`, `GetRetcodeID`, `GetErrorID`, `StringToTimeframe`, `getCandleData`, `fromDateTime`.

New private method declarations to add:

```mql5
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
```

New/updated `Processing` dispatch (add before the `if(StringLen(response) < 1)` guard):

```mql5
      if(action == "account") {
         response = getAccount();
      }

      if(action == "symbols") {
         id = jCommand.HasKey("id", jtSTR);
         if(id != NULL)
            response = getSymbolInfoFull(id.ToStr());
         else
            response = getSymbols();
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
```

New method implementations, using `CTrade`, `COrderInfo`, `CPositionInfo`, and guard limits:

- `getAccount()` — exposes `ACCOUNT_COMPANY`, `ACCOUNT_CURRENCY`, `ACCOUNT_SERVER`, `ACCOUNT_NAME`, `ACCOUNT_NUMBER`, `ACCOUNT_LEVERAGE`, `ACCOUNT_BALANCE`, `ACCOUNT_EQUITY`, `ACCOUNT_MARGIN`, `ACCOUNT_MARGIN_FREE`, `ACCOUNT_MARGIN_LEVEL`, `ACCOUNT_PROFIT`, `ACCOUNT_CREDIT`, `ACCOUNT_TRADE_MODE`, `ACCOUNT_MARGIN_SO_MODE`, `ACCOUNT_MARGIN_SO_SO`, `ACCOUNT_MARGIN_SO_CALL`, `ACCOUNT_TRADE_ALLOWED`, `ACCOUNT_TRADE_EXPERT`, `ACCOUNT_TRADE_FIFO`, `ACCOUNT_CURRENCY_DIGITS`, `ACCOUNT_STOPOUT_MODE`, `ACCOUNT_STOPOUT_LEVEL`.
- `getSymbols()` — loops `SymbolsTotal(false)` and returns a JSON array of names.
- `getSymbolInfoFull(name)` — existing `getSymbolInfo` fields plus `SYMBOL_TRADE_TICK_SIZE`, `SYMBOL_TRADE_TICK_VALUE`, `SYMBOL_TRADE_CONTRACT_SIZE`, `SYMBOL_VOLUME_MIN/MAX/STEP`, `SYMBOL_SESSION_OPEN/CLOSE` (for current day/period), `SYMBOL_SPREAD`, `SYMBOL_SWAP_LONG`, `SYMBOL_SWAP_SHORT`, `SYMBOL_DIGITS`, `SYMBOL_TRADE_EXEMODE`, `SYMBOL_TRADE_FILLING`, `SYMBOL_TRADE_STOPS_LEVEL`, `SYMBOL_TRADE_FREEZE_LEVEL`.
- `getTick(symbol)` — `SymbolInfoTick`, returns bid/ask/last/volume/time/time_msc/flags.
- `getPositionsPnl()` — iterates positions, sums `POSITION_PROFIT` + `POSITION_SWAP`, and groups per symbol.
- `getMargin(symbol)` — uses `OrderCalcMargin` with a default order and returns the computed margin (requires a volume + type; if missing use 0.01 buy).
- `getAccountHistory(dataObject)` — for `from`/`to` timestamps, uses `HistorySelect` and returns profit summary (per-date equity proxy: sum of deal profits grouped by day).
- `tradeCloseAll()` — loops positions and closes each with `CTrade::PositionClose`.
- `tradeCloseSymbol(symbol)` — closes only positions matching symbol.
- `tradeBatch(dataObject)` — reads a `"trades"` array (cap 20), executes each via the existing `tradingModule` logic on a per-element basis, collects per-trade results into a JSON array. Enforce the 20-operation cap.

- [ ] **Step 2: Verify the file is saved as UTF-8 (no BOM) and compiles**

The file must be written via this tool (UTF-8). The EA must still call `api.Processing()` and dispatch.

- [ ] **Step 3: Commit**

```bash
git add MQL5/Include/RestApi.mqh
git commit -m "feat(mql5): full account/symbol/tick/pnl/margin/history + batch and close-all trading"
```

---

### Task 6: Update README + spec self-review closure

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update README** — add the new endpoints to the endpoint tables, add `/health` and `/version`, add the `/trade/batch` request format, note the batch 20-op cap, and add the new actions (`trade_close_all`, `trade_close_symbol`).

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: document production endpoints and batch trading"
```

---

### Task 7: Verify build (optional, requires toolchain)

**Files:** none.

- [ ] **Step 1: Build the DLL (if Visual Studio + cpprestsdk available)**

Open `mt5-rest.sln`, select `Release x64`, build. Fix any compile errors introduced by the API changes (especially `SafeVector` signature changes in `microsvc_controller.cpp` — ensure no stale calls to removed `begin`/`end`/`back`).

- [ ] **Step 2: Compile EA in MT5 (if available)**

Copy `MQL5/Include/RestApi.mqh` into the MT5 data folder and press F7 in the editor. Confirm no compile errors.

- [ ] **Step 3: Commit any build fixes**

```bash
git add -A
git commit -m "fix: resolve build errors from bridge hardening"
```
