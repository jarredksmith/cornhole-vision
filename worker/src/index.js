/**
 * Cornhole Vision — realtime backend.
 *
 * One Durable Object per game code. Scorer phones push live bag positions and
 * round results; viewers (the web page, other phones) receive the full state
 * on every change. State survives reconnects and is persisted to DO storage.
 *
 * Routes
 *   GET  /ws/:code?role=scorer|viewer&board=1|2   WebSocket
 *   GET  /api/:code                                JSON snapshot
 *   POST /api/:code/round  { result }              HTTP fallback for scorers
 *   GET  /health
 */

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET,POST,OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type',
};

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (request.method === 'OPTIONS') return new Response(null, { headers: CORS });
    if (url.pathname === '/health') return json({ ok: true, t: Date.now() });

    const ws = url.pathname.match(/^\/ws\/([A-Za-z0-9]{3,8})$/);
    const api = url.pathname.match(/^\/api\/([A-Za-z0-9]{3,8})(\/\w+)?$/);
    const code = (ws?.[1] || api?.[1] || '').toUpperCase();
    if (!code) return json({ error: 'not found' }, 404);

    const id = env.GAME_ROOM.idFromName(code);
    const stub = env.GAME_ROOM.get(id);
    return stub.fetch(request);
  },
};

function json(body, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json', ...CORS } });
}

const EMPTY = (code) => ({
  code,
  status: 'lobby',
  teams: [
    { name: 'Team 1', color: '#9E9E9E' },
    { name: 'Team 2', color: '#616161' },
  ],
  scores: [0, 0],
  rounds: [],
  roundNumber: 1,
  activeBoard: 1,
  live: null,
  winner: null,
  target: 21,
  updatedAt: Date.now(),
});

export class GameRoom {
  constructor(state, env) {
    this.state = state;
    this.env = env;
    this.sessions = new Map(); // WebSocket -> { role, board, name }
    this.game = null;
  }

  async load(code) {
    if (!this.game) {
      this.game = (await this.state.storage.get('game')) || EMPTY(code);
      // A room that has sat idle for 12 h starts fresh (game codes get reused).
      if (Date.now() - this.game.updatedAt > 12 * 3600 * 1000) this.game = EMPTY(code);
    }
    return this.game;
  }

  async save() {
    this.game.updatedAt = Date.now();
    await this.state.storage.put('game', this.game);
  }

  async fetch(request) {
    const url = new URL(request.url);
    const code = url.pathname.split('/')[2].toUpperCase();
    await this.load(code);

    if (url.pathname.startsWith('/ws/')) {
      if (request.headers.get('Upgrade') !== 'websocket') return json({ error: 'expected websocket' }, 426);
      const pair = new WebSocketPair();
      const [client, server] = Object.values(pair);
      this.accept(server, {
        role: url.searchParams.get('role') || 'viewer',
        board: Number(url.searchParams.get('board') || 1),
      });
      return new Response(null, { status: 101, webSocket: client });
    }

    if (url.pathname.endsWith('/round') && request.method === 'POST') {
      const body = await request.json().catch(() => ({}));
      if (body.result) {
        this.applyRound(body.result);
        await this.save();
        this.broadcast();
      }
      return json(this.game);
    }

    return json(this.game);
  }

  accept(ws, meta) {
    ws.accept();
    this.sessions.set(ws, meta);
    ws.send(JSON.stringify({ type: 'state', state: this.game }));
    ws.addEventListener('message', (ev) => this.onMessage(ws, ev).catch((e) => {
      try { ws.send(JSON.stringify({ type: 'error', error: String(e) })); } catch {}
    }));
    const close = () => this.sessions.delete(ws);
    ws.addEventListener('close', close);
    ws.addEventListener('error', close);
  }

  async onMessage(ws, ev) {
    let msg;
    try { msg = JSON.parse(ev.data); } catch { return; }
    const meta = this.sessions.get(ws) || {};
    const g = this.game;
    let changed = true;

    switch (msg.type) {
      case 'hello':
        meta.role = msg.role || meta.role;
        meta.board = msg.board || meta.board;
        meta.name = msg.name;
        this.sessions.set(ws, meta);
        ws.send(JSON.stringify({ type: 'state', state: g }));
        return;

      case 'setup':
        if (Array.isArray(msg.teams) && msg.teams.length === 2) g.teams = msg.teams;
        if (msg.target) g.target = msg.target;
        if (g.status === 'lobby') g.status = 'playing';
        break;

      case 'teams':
        if (Array.isArray(msg.teams) && msg.teams.length === 2) g.teams = msg.teams;
        break;

      case 'live':
        // In two-phone games only the active board's phone drives the live view;
        // a lone phone (solo mode) is always trusted, whichever board it says it's at.
        if (msg.live && (meta.role !== 'scorer' || this.scorerCount() <= 1 || msg.live.board === g.activeBoard)) {
          g.live = msg.live;
          if (g.status === 'lobby') g.status = 'playing';
        } else {
          changed = false;
        }
        break;

      case 'round':
        if (msg.result) this.applyRound(msg.result);
        break;

      case 'undo': {
        const last = g.rounds.pop();
        if (last) {
          g.scores = [g.scores[0] - last.pointsA, g.scores[1] - last.pointsB];
          g.roundNumber = g.rounds.length + 1;
          g.activeBoard = last.board;
          g.winner = null;
          g.status = 'playing';
        }
        break;
      }

      case 'reset':
        this.game = EMPTY(g.code);
        break;

      case 'ping':
        ws.send(JSON.stringify({ type: 'pong' }));
        return;

      default:
        return;
    }

    if (changed) {
      // Persist rounds/scores immediately; throttle live-position writes.
      if (msg.type !== 'live') await this.save();
      else this.game.updatedAt = Date.now();
      this.broadcast();
    }
  }

  scorerCount() {
    let n = 0;
    for (const [, m] of this.sessions) if (m.role === 'scorer') n++;
    return n;
  }

  applyRound(result) {
    const g = this.game;
    // Ignore duplicates (the phone may resend after a reconnect).
    if (g.rounds.some((r) => r.number === result.number)) return;
    const diff = (result.a.on + 3 * result.a.in) - (result.b.on + 3 * result.b.in);
    const r = { ...result, number: g.rounds.length + 1, pointsA: Math.max(0, diff), pointsB: Math.max(0, -diff) };
    g.rounds.push(r);
    g.scores = [g.scores[0] + r.pointsA, g.scores[1] + r.pointsB];
    g.roundNumber = g.rounds.length + 1;
    g.activeBoard = r.board === 1 ? 2 : 1;
    g.live = { board: g.activeBoard, bags: [], a: { on: 0, in: 0 }, b: { on: 0, in: 0 } };
    g.status = 'playing';
    const t = g.target || 21;
    if (g.scores[0] >= t && g.scores[0] > g.scores[1]) { g.winner = 0; g.status = 'finished'; }
    else if (g.scores[1] >= t && g.scores[1] > g.scores[0]) { g.winner = 1; g.status = 'finished'; }
  }

  broadcast() {
    const payload = JSON.stringify({ type: 'state', state: this.game });
    for (const [ws] of this.sessions) {
      try { ws.send(payload); } catch { this.sessions.delete(ws); }
    }
  }
}
