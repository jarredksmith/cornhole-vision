# cornhole-live (Cloudflare Worker)

Realtime game rooms: one Durable Object per 4-letter game code. The phone
pushes bag positions and round results; the web page and any other phones get
the full game state on every change.

## Deploy

```bash
cd worker
npm install
npx wrangler login          # once
npx wrangler deploy
```

Wrangler prints the URL, e.g. `https://cornhole-live.<you>.workers.dev`.
Put that in `ios/CornholeVision/App/AppConfig.swift` (`syncBaseURL`) and in
`web/index.html` (`WORKER_URL`).

Durable Objects need a Workers Paid plan ($5/mo) *or* the free tier with
SQLite-backed DOs — if `wrangler deploy` complains, change the migration in
`wrangler.toml` to `new_sqlite_classes = ["GameRoom"]`.

## Protocol

Client → server (JSON over WebSocket at `/ws/CODE?role=scorer|viewer&board=1|2`):

| type    | payload                                   |
|---------|-------------------------------------------|
| hello   | role, board, name                         |
| setup   | teams [{name,color}], target              |
| teams   | teams                                     |
| live    | live {board, bags[{id,team,x,y,state}], a{on,in}, b{on,in}} |
| round   | result {number, board, a, b}              |
| undo    |                                           |
| reset   |                                           |

Server → client: `{ "type": "state", "state": {...} }` after every change.
`GET /api/CODE` returns the same state as JSON.

Positions are board inches: x 0–24 across, y 0–48 along, y = 0 at the hole end.
