# MT5 REST API

Turns MetaTrader 5 into a REST API server for algorithmic trading.

## Requirements

- MetaTrader 5 (64-bit)
- Visual C++ Redistributable 2017: https://aka.ms/vs/15/release/vc_redist.x64.exe

## Installation

1. Clone repo to any folder on your PC
2. Copy `MQL5` folder to MT5 Data folder (`File → Open Data Folder` or `Ctrl+Shift+D`)
3. Copy all DLLs from `MQL5/Libraries/` to the same location
4. In MT5 Navigator (`Ctrl+N`), right-click `Expert Advisors → RestApi → Modify`
5. Press `F7` to compile
6. Drag EA onto a chart

## EA Configuration

| Parameter | Description | Example |
|-----------|-------------|---------|
| host | Listen address | `http://YOUR_SERVER_IP` |
| port | Port number | `6542` |
| AuthToken | Authentication token | `your-secret-token` |

**Important:** On Windows, use your server IP instead of `http://0.0.0.0`

## API Endpoints

All endpoints require an `Authorization` header with your token (`Authorization: your-token`), except the operational endpoints below (`/health`, `/version`) and `OPTIONS` preflight requests.

### Operational

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/health` | GET | Health check: uptime, queue depth, MQL5 connection status. Does **not** require `Authorization`. |
| `/version` | GET | Protocol version, e.g. `{"version":"1", ...}`. Does **not** require `Authorization`. |
| `/ping` | GET | Liveness probe: `pong`, `time`, `terminal_build`, `deals_total`, `orders_total`, `positions_total`, `server`, `account` (requires `Authorization`). |
| `OPTIONS` (any path) | OPTIONS | CORS preflight. Returns `Allow: GET, POST, PUT, PATCH, DELETE, OPTIONS, HEAD`. `HEAD` is also supported. |

Every response includes CORS headers (`Access-Control-Allow-Origin: *`). On errors the server returns a structured JSON body:

```json
{
  "code": 401,
  "message": "Unauthorized",
  "request_id": "20260902...-1"
}
```

Common HTTP status codes include `401` (unauthorized), `413` (request too large), `503` (command queue full), and `504` (command wait timeout).

### Account & Info

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/info` | GET | Account details, balance, equity, margin |
| `/balance` | GET | Balance, equity, margin info |
| `/account` | GET | Full account properties (company, currency, server, name, number, leverage, balance, equity, margin, margin_free, margin_level, profit, credit, stopout, trade settings, etc.) |
| `/symbols` | GET | List all symbols with lightweight specs (name, digits, point, spread, volumes, trade_mode, sessions) |
| `/symbols/{name}` | GET | Full symbol info (ask/bid, tick_size/value, contract_size, volumes, spread, digits, swap_long/short, trade_mode/exemode/filling, stops/freeze, point, ticks_book_depth, margin/profit/trade/base/quote currencies, calc/swap/expiration modes, volume_limit, margins, sessions) |
| `/tick/{symbol}` | GET | Latest tick: bid, ask, last, volume, time, time_msc, flags |
| `/positions_pnl` | GET | Aggregate realized + unrealized PnL grouped per symbol (profit, swap) |
| `/margin/{symbol}` | GET | Margin calculation (default: 0.01 buy lot) |
| `/account_history` | GET | Account deals history: total PnL grouped by day, via `from`/`to` timestamps |

> **Note:** `/info` `orders_total` and `/balance` `orders_total`/`deal_total` are **last-1-day** counts (bounded `HistorySelect`). Full all-time totals are available via `/ping` (`deals_total`/`orders_total`/`positions_total`) and via the paginated `total` field on `/deals` and `/history`.

### Positions & Orders

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/positions` | GET | List all open positions (each includes `profit`, `swap`, `comment`, `price_current`) |
| `/positions/{id}` | GET | Get position by ID |
| `/positions/{id}` | DELETE | Close position by ID (REST-style shortcut) |
| `/positions/{id}` | PUT/PATCH | Modify position (stoploss/takeprofit) |
| `/orders` | GET | List pending orders |
| `/orders/{id}` | GET | Get order by ID |
| `/orders/{id}` | DELETE | Cancel pending order by ID (REST-style shortcut) |
| `/orders/{id}` | PUT/PATCH | Modify pending order |
| `/history` | GET | List order history (query: `offset`, `limit`, `position_id`, `symbol`, `from`, `to`) — returns `{orders:[...], total:N}` with `fill` price for filled orders |
| `/history/{id}` | GET | Get history order by ID |
| `/deals` | GET | List deals (query: `offset`, `limit`, `position_id`, `symbol`, `from`, `to`) — returns `{deals:[...], total:N}` with `entry`/`reason`/`swap`/`comment` |
| `/deals/{id}` | GET | Get deal by ID |

### Historical Data (OHLCV)

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/candles/{symbol}` | GET | Historical candlestick data |

**Query Parameters:**
- `timeframe`: M1, M5, M15, M30, H1, H4, D1, W1, MN1 (default: H1)
- `count`: Number of candles, 1-1000 (default: 100)
- `start_pos`: Start position, 0 = current candle (default: 0)

**Example:**
```bash
curl -H "Authorization: your-token" "http://localhost:6542/candles/EURGBP?timeframe=H1&count=100"
```

**Response:**
```json
{
  "symbol": "EURGBP",
  "timeframe": "H1",
  "count": 100,
  "candles": [
    {
      "time": "2025-12-02T22:00:00.000Z",
      "open": 0.87971,
      "high": 0.87994,
      "low": 0.87966,
      "close": 0.87985,
      "tick_volume": 1241,
      "spread": 0,
      "real_volume": 0
    }
  ]
}
```

### Trading

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/trade` | POST | Execute a trading action |
| `/trade/close_all` | POST | Close **all** open positions |
| `/trade/close_symbol/{symbol}` | POST | Close all positions of one symbol |
| `/trade/batch` | POST | Execute up to 20 trade operations in a single request |

## Trade Examples

### Open Buy
```json
{
  "symbol": "EURUSD",
  "actionType": "ORDER_TYPE_BUY",
  "volume": 0.1,
  "stoploss": 1.09000,
  "takeprofit": 1.11000,
  "comment": "Buy order"
}
```

### Open Sell
```json
{
  "symbol": "EURUSD",
  "actionType": "ORDER_TYPE_SELL",
  "volume": 0.1,
  "stoploss": 1.11000,
  "takeprofit": 1.09000,
  "comment": "Sell order"
}
```

### Pending Orders
```json
// Buy Limit
{ "symbol": "EURUSD", "actionType": "ORDER_TYPE_BUY_LIMIT", "price": 1.08000, "volume": 0.1, "stoploss": 1.07000, "takeprofit": 1.10000 }

// Sell Limit
{ "symbol": "EURUSD", "actionType": "ORDER_TYPE_SELL_LIMIT", "price": 1.12000, "volume": 0.1, "stoploss": 1.13000, "takeprofit": 1.10000 }

// Buy Stop
{ "symbol": "EURUSD", "actionType": "ORDER_TYPE_BUY_STOP", "price": 1.12000, "volume": 0.1, "stoploss": 1.11000, "takeprofit": 1.14000 }

// Sell Stop
{ "symbol": "EURUSD", "actionType": "ORDER_TYPE_SELL_STOP", "price": 1.08000, "volume": 0.1, "stoploss": 1.09000, "takeprofit": 1.06000 }
```

### Position Management
```json
// Close position by ID
{ "actionType": "POSITION_CLOSE_ID", "id": 123456789 }

// Partial close
{ "actionType": "POSITION_PARTIAL", "id": 123456789, "volume": 0.05 }

// Modify position
{ "actionType": "POSITION_MODIFY", "id": 123456789, "stoploss": 1.08500, "takeprofit": 1.11500 }

// Cancel pending order
{ "actionType": "ORDER_CANCEL", "id": 123456789 }
```

### Batch Trading

Execute multiple trade operations in one request to `/trade/batch`. The body wraps an array of trade actions under a `trades` key (each action uses the same format as `POST /trade`). The batch is capped at **20** operations per request.

```json
{
  "trades": [
    { "symbol": "EURUSD", "actionType": "ORDER_TYPE_BUY", "volume": 0.1, "stoploss": 1.09000, "takeprofit": 1.11000 },
    { "symbol": "GBPUSD", "actionType": "ORDER_TYPE_SELL", "volume": 0.1, "stoploss": 1.27000, "takeprofit": 1.24000 },
    { "actionType": "POSITION_CLOSE_ID", "id": 123456789 }
  ]
}
```

**Response:**
```json
{
  "count": 3,
  "results": [
    { "error": 10009, "description": "TRADE_RETCODE_DONE", "order_id": 405895526, "function": "CRestApi::tradingModule" },
    { "error": 10009, "description": "TRADE_RETCODE_DONE", "order_id": 405895527, "function": "CRestApi::tradingModule" },
    { "error": 10009, "description": "TRADE_RETCODE_DONE", "order_id": 0, "function": "CRestApi::tradingModule" }
  ]
}
```
`count` is the number of operations executed; if more than 20 were sent, a `cap` field is included. Each element of `results` uses the same shape as the single `/trade` response below.

## Trade Response

```json
{
  "retcode": 10009,
  "retcode_external": 0,
  "order_id": 405895526,
  "deal_id": 405895527,
  "position_id": 405895527,
  "symbol": "EURUSD",
  "type": "ORDER_TYPE_BUY",
  "price": 1.13047,
  "volume": 0.1,
  "bid": 1.13038,
  "ask": 1.13047,
  "time": "2026-09-02T12:00:00.000Z",
  "error": 10009,
  "description": "TRADE_RETCODE_DONE",
  "function": "CRestApi::tradingModule"
}
```

`retcode`/`retcode_external`/`order_id`/`deal_id`/`position_id`/`symbol`/`type`/`price`/`time` are the real fill tickets; `error`/`description` are the legacy aliases. `position_id` is best-effort (0 when not applicable).

**Common Return Codes:**
- `10009` - TRADE_RETCODE_DONE (Success)
- `10018` - TRADE_RETCODE_MARKET_CLOSED
- `10016` - TRADE_RETCODE_INVALID_STOPS
- `10019` - TRADE_RETCODE_NO_MONEY

Full list: https://www.mql5.com/en/docs/constants/errorswarnings/enum_trade_return_codes

## Building from Source

To compile the C++ DLL:
1. Open `mt5-rest.sln` in Visual Studio 2017+
2. Select `Release x64`
3. Build (`Ctrl+Shift+B`)
4. Output: `/x64/Release/mt5-rest.dll`

## References

- DateTime format: https://www.mql5.com/en/docs/basis/types/integer/datetime
- Enums: https://www.mql5.com/en/docs/constants
- Trade codes: https://www.mql5.com/en/docs/constants/errorswarnings/enum_trade_return_codes
