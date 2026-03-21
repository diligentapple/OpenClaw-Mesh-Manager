'use strict';

const http = require('http');
const WebSocket = require('ws');
const fs = require('fs');
const crypto = require('crypto');

const CONFIG_PATH = process.env.BRIDGE_CONFIG || '/data/config.json';
const PORT = parseInt(process.env.BRIDGE_PORT || '3000', 10);
const RESPONSE_TIMEOUT = parseInt(process.env.RESPONSE_TIMEOUT || '120000', 10);
const ROSTER_DEBOUNCE_MS = parseInt(process.env.ROSTER_DEBOUNCE_MS || '15000', 10);
const RECONNECT_BASE_MS = parseInt(process.env.RECONNECT_BASE_MS || '10000', 10);
const RECONNECT_MAX_MS = parseInt(process.env.RECONNECT_MAX_MS || '120000', 10);

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------
function loadConfig() {
  return JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8'));
}

// ---------------------------------------------------------------------------
// Gateway WebSocket Client
// ---------------------------------------------------------------------------
class GatewayClient {
  constructor(instanceId, host, port, token) {
    this.instanceId = instanceId;
    this.url = `ws://${host}:${port}`;
    this.token = token;
    this.ws = null;
    this.connected = false;
    this.pending = new Map();          // reqId -> {resolve, reject, timer}
    this.chatWaiters = [];             // [{matchFn, resolve, reject, timer, _id}]
    this._reqId = 0;
    this._connecting = null;
    this._reconnectTimer = null;
    this._reconnectAttempt = 0;
    this._shouldReconnect = false;     // set to true once first connection succeeds
    this.onStateChange = null;         // (instanceId, connected) => void
  }

  async ensureConnected() {
    if (this.connected && this.ws && this.ws.readyState === WebSocket.OPEN) return;
    if (this._connecting) return this._connecting;
    this._connecting = this._connect();
    try { await this._connecting; } finally { this._connecting = null; }
  }

  _connect() {
    return new Promise((resolve, reject) => {
      const ws = new WebSocket(this.url);
      this.ws = ws;

      const timeout = setTimeout(() => {
        ws.close();
        reject(new Error(`Connection timeout to instance ${this.instanceId}`));
      }, 15000);

      ws.on('error', (err) => {
        clearTimeout(timeout);
        this.connected = false;
        reject(err);
      });

      ws.on('close', () => {
        const wasConnected = this.connected;
        this.connected = false;
        if (wasConnected && this.onStateChange) this.onStateChange(this.instanceId, false);
        for (const [, p] of this.pending) {
          clearTimeout(p.timer);
          p.reject(new Error('connection closed'));
        }
        this.pending.clear();
        for (const w of this.chatWaiters) {
          clearTimeout(w.timer);
          w.reject(new Error('connection closed'));
        }
        this.chatWaiters = [];
        // Auto-reconnect if this client was previously connected successfully
        if (this._shouldReconnect) this._scheduleReconnect();
      });

      ws.on('message', (data) => {
        let msg;
        try { msg = JSON.parse(data.toString()); } catch { return; }

        // --- challenge-response auth ---
        if (msg.type === 'event' && msg.event === 'connect.challenge') {
          this._send('connect', {
            minProtocol: 3,
            maxProtocol: 3,
            client: {
              id: 'openclaw-bridge',
              version: '1.0.0',
              platform: 'linux',
              mode: 'backend',
            },
            role: 'operator',
            scopes: ['operator.admin'],
            auth: { token: this.token },
          }).then(() => {
            clearTimeout(timeout);
            this.connected = true;
            this._shouldReconnect = true;
            this._reconnectAttempt = 0;
            console.log(`[bridge] Connected to instance ${this.instanceId}`);
            if (this.onStateChange) this.onStateChange(this.instanceId, true);
            resolve();
          }).catch((err) => {
            clearTimeout(timeout);
            reject(err);
          });
          return;
        }

        // --- request responses ---
        if (msg.type === 'res') {
          const p = this.pending.get(msg.id);
          if (p) {
            this.pending.delete(msg.id);
            clearTimeout(p.timer);
            if (msg.ok) p.resolve(msg.payload);
            else p.reject(new Error(msg.error?.message || 'request failed'));
          }
          return;
        }

        // --- chat events (delta / final / error / aborted) ---
        if (msg.type === 'event' && msg.event === 'chat') {
          const payload = msg.payload;
          if (!payload) return;
          const terminal = ['final', 'error', 'aborted'].includes(payload.state);
          if (!terminal) return;

          const idx = this.chatWaiters.findIndex(w => w.matchFn(payload));
          if (idx !== -1) {
            const waiter = this.chatWaiters.splice(idx, 1)[0];
            clearTimeout(waiter.timer);
            if (payload.state === 'final') {
              waiter.resolve(payload);
            } else {
              waiter.reject(new Error(`chat ${payload.state}: ${payload.errorMessage || ''}`));
            }
          }
          return;
        }
      });
    });
  }

  _send(method, params) {
    return new Promise((resolve, reject) => {
      const id = String(++this._reqId);
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`Request timeout: ${method}`));
      }, 30000);
      this.pending.set(id, { resolve, reject, timer });
      this.ws.send(JSON.stringify({ type: 'req', id, method, params }));
    });
  }

  async request(method, params) {
    await this.ensureConnected();
    return this._send(method, params);
  }

  /** Wait for a terminal chat event matching the given sessionKey / runId. */
  waitForChat(sessionKey, runId, timeoutMs) {
    return new Promise((resolve, reject) => {
      const _id = crypto.randomUUID();
      const timer = setTimeout(() => {
        const idx = this.chatWaiters.findIndex(w => w._id === _id);
        if (idx !== -1) this.chatWaiters.splice(idx, 1);
        reject(new Error(`Chat response timeout (${timeoutMs}ms)`));
      }, timeoutMs);

      const matchFn = (payload) => {
        if (runId && payload.runId) return payload.runId === runId;
        return payload.sessionKey === sessionKey;
      };

      this.chatWaiters.push({ matchFn, resolve, reject, timer, _id });
    });
  }

  _scheduleReconnect() {
    if (this._reconnectTimer) return;
    const delay = Math.min(
      RECONNECT_BASE_MS * Math.pow(2, this._reconnectAttempt),
      RECONNECT_MAX_MS,
    );
    this._reconnectAttempt++;
    console.log(`[bridge] Will retry instance ${this.instanceId} in ${Math.round(delay / 1000)}s`);
    this._reconnectTimer = setTimeout(() => {
      this._reconnectTimer = null;
      this.ensureConnected()
        .then(() => {
          console.log(`[bridge] Reconnected to instance ${this.instanceId}`);
        })
        .catch((err) => {
          console.warn(`[bridge] Reconnect to instance ${this.instanceId} failed: ${err.message}`);
          this._scheduleReconnect();
        });
    }, delay);
  }

  close() {
    this._shouldReconnect = false;
    if (this._reconnectTimer) {
      clearTimeout(this._reconnectTimer);
      this._reconnectTimer = null;
    }
    if (this.ws) {
      try { this.ws.close(); } catch { /* ignore */ }
    }
  }
}

// ---------------------------------------------------------------------------
// Connection Pool
// ---------------------------------------------------------------------------
const clients = new Map();

async function getClient(instanceId) {
  const key = String(instanceId);
  let client = clients.get(key);
  if (client && client.connected) return client;

  if (client) { client.close(); clients.delete(key); }

  const config = loadConfig();
  const inst = config.instances[key];
  if (!inst) throw new Error(`Instance ${instanceId} not found in mesh config`);

  client = new GatewayClient(
    instanceId,
    inst.host,
    inst.port || 18789,
    inst.token,
  );
  client.onStateChange = (id, connected) => {
    console.log(`[bridge] Instance ${id} ${connected ? 'came online' : 'went offline'}`);
    scheduleRosterBroadcast();
  };
  clients.set(key, client);
  await client.ensureConnected();
  return client;
}

// ---------------------------------------------------------------------------
// Auto-Discovery: debounced roster broadcast on connect/disconnect
// ---------------------------------------------------------------------------
let _rosterTimer = null;

function scheduleRosterBroadcast() {
  if (_rosterTimer) clearTimeout(_rosterTimer);
  _rosterTimer = setTimeout(() => {
    _rosterTimer = null;
    broadcastRoster().catch(err => {
      console.error('[bridge] Roster broadcast failed:', err.message);
    });
  }, ROSTER_DEBOUNCE_MS);
}

async function broadcastRoster() {
  const config = loadConfig();
  const entries = Object.entries(config.instances);
  if (entries.length === 0) return;

  // Build roster text
  const networkName = config.networkName || 'mesh';
  const bridgeHost = config.bridgeHost || 'openclaw-bridge';
  const bridgePort = config.bridgePort || 3000;

  const lines = entries.map(([id, inst]) => {
    const connected = clients.has(id) && clients.get(id).connected;
    let line = `  • Instance ${id}`;
    if (inst.name) line += ` (${inst.name})`;
    if (inst.description) line += ` — ${inst.description}`;
    line += connected ? '  [online]' : '  [offline]';
    return line;
  });

  const roster =
    `[OpenClaw Mesh Network: ${networkName}] Connected instances:\n` +
    lines.join('\n') +
    `\n\nTo message another instance: curl -s -X POST http://${bridgeHost}:${bridgePort}/send ` +
    `-H "Content-Type: application/json" -d '{"to": N, "message": "..."}' ` +
    `\nTo see all instances: curl -s http://${bridgeHost}:${bridgePort}/instances`;

  console.log(`[bridge] Broadcasting roster to ${entries.length} instance(s)...`);

  // Inject into every connected instance (best-effort, don't fail the whole batch)
  const results = await Promise.allSettled(
    entries.map(async ([id]) => {
      const client = clients.get(id);
      if (!client || !client.connected) return;
      await client.request('chat.inject', {
        sessionKey: 'main',
        message: roster,
        label: 'mesh-roster',
      });
      console.log(`[bridge]   Instance #${id}: roster delivered`);
    })
  );

  const failed = results.filter(r => r.status === 'rejected');
  if (failed.length > 0) {
    console.warn(`[bridge]   ${failed.length} instance(s) unreachable for roster delivery`);
  }
}

// ---------------------------------------------------------------------------
// HTTP helpers
// ---------------------------------------------------------------------------
function readBody(req) {
  return new Promise((resolve, reject) => {
    let body = '';
    req.on('data', (c) => (body += c));
    req.on('end', () => {
      try { resolve(JSON.parse(body)); }
      catch { reject(new Error('Invalid JSON body')); }
    });
    req.on('error', reject);
  });
}

function sendJson(res, status, data) {
  res.writeHead(status, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(data));
}

function extractText(message) {
  if (!message) return '';
  if (typeof message === 'string') return message;
  if (typeof message.text === 'string') return message.text;
  if (Array.isArray(message.content)) {
    return message.content
      .filter((c) => c.type === 'text')
      .map((c) => c.text || '')
      .join('\n');
  }
  return JSON.stringify(message);
}

// ---------------------------------------------------------------------------
// HTTP Server
// ---------------------------------------------------------------------------
const server = http.createServer(async (req, res) => {
  try {
    // ---- GET /health ----
    if (req.method === 'GET' && req.url === '/health') {
      return sendJson(res, 200, { status: 'ok', connections: clients.size });
    }

    // ---- GET /instances ----
    if (req.method === 'GET' && req.url === '/instances') {
      const config = loadConfig();
      const instances = Object.entries(config.instances).map(([id, inst]) => ({
        id: Number(id),
        name: inst.name || `Instance ${id}`,
        description: inst.description || '',
        host: inst.host,
        connected: clients.has(id) && clients.get(id).connected,
      }));
      return sendJson(res, 200, { instances });
    }

    // ---- POST /send ----
    // Send a user message to an instance and wait for the agent response.
    //   { to: N, message: "...", sessionKey?: "..." }
    if (req.method === 'POST' && req.url === '/send') {
      const body = await readBody(req);
      const { to, message, sessionKey } = body;

      if (!to || !message) {
        return sendJson(res, 400, {
          ok: false,
          error: 'Missing "to" (instance number) or "message"',
        });
      }

      const client = await getClient(to);
      const key = sessionKey || 'main';
      const idempotencyKey = crypto.randomUUID();

      // Register waiter BEFORE sending so we don't miss fast responses
      const responsePromise = client.waitForChat(key, null, RESPONSE_TIMEOUT);

      await client.request('chat.send', {
        sessionKey: key,
        message: String(message),
        deliver: false,
        idempotencyKey,
      });

      const chatPayload = await responsePromise;
      const text = extractText(chatPayload.message);

      return sendJson(res, 200, {
        ok: true,
        from: to,
        sessionKey: key,
        response: text,
      });
    }

    // ---- POST /inject ----
    // Inject an assistant message into a session (broadcasts to Telegram etc).
    //   { instance: N, sessionKey: "agent:main:telegram:direct:...", message: "..." }
    if (req.method === 'POST' && req.url === '/inject') {
      const body = await readBody(req);
      const { instance, sessionKey, message, label } = body;

      if (!instance || !sessionKey || !message) {
        return sendJson(res, 400, {
          ok: false,
          error: 'Missing "instance", "sessionKey", or "message"',
        });
      }

      const client = await getClient(instance);
      const result = await client.request('chat.inject', {
        sessionKey,
        message: String(message),
        label: label || 'mesh-relay',
      });

      return sendJson(res, 200, { ok: true, result });
    }

    // ---- POST /relay ----
    // Send a message to instance B, wait for the response, then inject it
    // back into instance A's session (e.g. a Telegram conversation).
    //   { from: N, fromSessionKey: "agent:main:telegram:direct:...",
    //     to: M, message: "...", toSessionKey?: "..." }
    if (req.method === 'POST' && req.url === '/relay') {
      const body = await readBody(req);
      const { from, fromSessionKey, to, message, toSessionKey } = body;

      if (!from || !fromSessionKey || !to || !message) {
        return sendJson(res, 400, {
          ok: false,
          error: 'Missing required fields: from, fromSessionKey, to, message',
        });
      }

      // Send to the target instance
      const targetClient = await getClient(to);
      const tKey = toSessionKey || 'main';
      const idempotencyKey = crypto.randomUUID();
      const responsePromise = targetClient.waitForChat(tKey, null, RESPONSE_TIMEOUT);

      await targetClient.request('chat.send', {
        sessionKey: tKey,
        message: String(message),
        deliver: false,
        idempotencyKey,
      });

      const chatPayload = await responsePromise;
      const text = extractText(chatPayload.message);

      // Inject the response back into the source instance's session
      const sourceClient = await getClient(from);
      await sourceClient.request('chat.inject', {
        sessionKey: fromSessionKey,
        message: text,
        label: `Response from instance ${to}`,
      });

      return sendJson(res, 200, {
        ok: true,
        response: text,
        injected: true,
      });
    }

    // ---- POST /announce ----
    // Manually trigger a roster broadcast to all connected instances.
    if (req.method === 'POST' && req.url === '/announce') {
      await broadcastRoster();
      return sendJson(res, 200, { ok: true, message: 'Roster broadcast complete' });
    }

    sendJson(res, 404, {
      error: 'Not found. Endpoints: GET /health, GET /instances, POST /send, POST /inject, POST /relay, POST /announce',
    });
  } catch (err) {
    console.error('[bridge] Error:', err.message);
    sendJson(res, 500, { ok: false, error: err.message });
  }
});

// ---------------------------------------------------------------------------
// Start
// ---------------------------------------------------------------------------
server.listen(PORT, '0.0.0.0', () => {
  console.log(`[bridge] OpenClaw Mesh Bridge v1.0.0`);
  console.log(`[bridge] Listening on :${PORT}`);
  console.log(`[bridge] Config: ${CONFIG_PATH}`);

  // Pre-connect to all configured instances.  Each successful connection
  // triggers scheduleRosterBroadcast via onStateChange.  If an instance
  // isn't up yet, we enable _shouldReconnect so the client keeps retrying
  // with exponential backoff until it comes online.
  try {
    const config = loadConfig();
    for (const id of Object.keys(config.instances)) {
      getClient(id).catch((err) => {
        console.warn(`[bridge] Pre-connect to instance ${id} failed: ${err.message}`);
        // Enable auto-reconnect even though initial connect failed — the
        // instance may still be booting.  getClient stores the client in
        // the pool before attempting connection, so it's available here.
        const client = clients.get(id);
        if (client && !client._reconnectTimer) {
          client._shouldReconnect = true;
          client._scheduleReconnect();
        }
      });
    }
  } catch (e) {
    console.warn('[bridge] Config load failed:', e.message);
  }
});

// Graceful shutdown
process.on('SIGTERM', () => {
  console.log('[bridge] Shutting down...');
  for (const client of clients.values()) client.close();
  server.close(() => process.exit(0));
});

process.on('SIGINT', () => {
  for (const client of clients.values()) client.close();
  server.close(() => process.exit(0));
});
