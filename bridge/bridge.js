'use strict';

const http = require('http');
const WebSocket = require('ws');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

// Prevent unhandled promise rejections from crashing the bridge.
// These can happen when a WebSocket closes while chat waiters are pending.
process.on('unhandledRejection', (err) => {
  console.warn('[bridge] Unhandled rejection:', err.message || err);
});

const CONFIG_PATH = process.env.BRIDGE_CONFIG || '/data/config.json';
const BRIDGE_STATE_DIR = process.env.BRIDGE_STATE_DIR || '/data/state';
const PORT = parseInt(process.env.BRIDGE_PORT || '3000', 10);
const RESPONSE_TIMEOUT = parseInt(process.env.RESPONSE_TIMEOUT || '120000', 10);
const ROSTER_DEBOUNCE_MS = parseInt(process.env.ROSTER_DEBOUNCE_MS || '15000', 10);
const RECONNECT_BASE_MS = parseInt(process.env.RECONNECT_BASE_MS || '10000', 10);
const RECONNECT_MAX_MS = parseInt(process.env.RECONNECT_MAX_MS || '120000', 10);
const ROSTER_READY_DELAY_MS = parseInt(process.env.ROSTER_READY_DELAY_MS || '60000', 10);
const AGENT_WAIT_TIMEOUT_PADDING_MS = parseInt(
  process.env.AGENT_WAIT_TIMEOUT_PADDING_MS || '5000',
  10,
);
const CHAT_EVENT_GRACE_MS = parseInt(process.env.CHAT_EVENT_GRACE_MS || '1500', 10);
const HISTORY_POLL_ATTEMPTS = parseInt(process.env.HISTORY_POLL_ATTEMPTS || '4', 10);
const HISTORY_POLL_INTERVAL_MS = parseInt(process.env.HISTORY_POLL_INTERVAL_MS || '750', 10);
const HISTORY_POLL_LIMIT = parseInt(process.env.HISTORY_POLL_LIMIT || '20', 10);
const BRIDGE_CLIENT_ID = process.env.BRIDGE_CLIENT_ID || 'gateway-client';
const BRIDGE_DEVICE_FAMILY = process.env.BRIDGE_DEVICE_FAMILY || 'server';
const BRIDGE_SCOPES = [
  'operator.admin',
  'operator.read',
  'operator.write',
  'operator.approvals',
  'operator.pairing',
];
const ED25519_SPKI_PREFIX = Buffer.from('302a300506032b6570032100', 'hex');

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------
function loadConfig() {
  return JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8'));
}

function ensureParentDir(filePath) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
}

function readJsonFile(filePath) {
  try {
    if (!fs.existsSync(filePath)) return null;
    return JSON.parse(fs.readFileSync(filePath, 'utf8'));
  } catch {
    return null;
  }
}

function writeJsonFile(filePath, value) {
  ensureParentDir(filePath);
  fs.writeFileSync(filePath, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 });
  try { fs.chmodSync(filePath, 0o600); } catch { /* ignore */ }
}

function base64UrlEncode(buffer) {
  return buffer
    .toString('base64')
    .replaceAll('+', '-')
    .replaceAll('/', '_')
    .replace(/=+$/g, '');
}

function derivePublicKeyRaw(publicKeyPem) {
  const spki = crypto.createPublicKey(publicKeyPem).export({
    type: 'spki',
    format: 'der',
  });
  if (
    spki.length === ED25519_SPKI_PREFIX.length + 32 &&
    spki.subarray(0, ED25519_SPKI_PREFIX.length).equals(ED25519_SPKI_PREFIX)
  ) {
    return spki.subarray(ED25519_SPKI_PREFIX.length);
  }
  return spki;
}

function fingerprintPublicKey(publicKeyPem) {
  return crypto.createHash('sha256').update(derivePublicKeyRaw(publicKeyPem)).digest('hex');
}

function resolveBridgeIdentityPath() {
  return path.join(BRIDGE_STATE_DIR, 'identity', 'device.json');
}

function resolveBridgeDeviceAuthPath() {
  return path.join(BRIDGE_STATE_DIR, 'identity', 'device-auth.json');
}

function createBridgeDeviceIdentity() {
  const { publicKey, privateKey } = crypto.generateKeyPairSync('ed25519');
  const publicKeyPem = publicKey.export({ type: 'spki', format: 'pem' }).toString();
  const privateKeyPem = privateKey.export({ type: 'pkcs8', format: 'pem' }).toString();
  return {
    deviceId: fingerprintPublicKey(publicKeyPem),
    publicKeyPem,
    privateKeyPem,
  };
}

function loadOrCreateBridgeDeviceIdentity() {
  const filePath = resolveBridgeIdentityPath();
  const parsed = readJsonFile(filePath);
  if (
    parsed &&
    parsed.version === 1 &&
    typeof parsed.deviceId === 'string' &&
    typeof parsed.publicKeyPem === 'string' &&
    typeof parsed.privateKeyPem === 'string'
  ) {
    const deviceId = fingerprintPublicKey(parsed.publicKeyPem);
    if (deviceId !== parsed.deviceId) {
      writeJsonFile(filePath, {
        ...parsed,
        deviceId,
      });
    }
    return {
      deviceId,
      publicKeyPem: parsed.publicKeyPem,
      privateKeyPem: parsed.privateKeyPem,
    };
  }

  const identity = createBridgeDeviceIdentity();
  writeJsonFile(filePath, {
    version: 1,
    ...identity,
    createdAtMs: Date.now(),
  });
  return identity;
}

function publicKeyRawBase64UrlFromPem(publicKeyPem) {
  return base64UrlEncode(derivePublicKeyRaw(publicKeyPem));
}

function signDevicePayload(privateKeyPem, payload) {
  return base64UrlEncode(
    crypto.sign(null, Buffer.from(payload, 'utf8'), crypto.createPrivateKey(privateKeyPem)),
  );
}

function normalizeDeviceAuthMetadata(value) {
  if (typeof value !== 'string') return '';
  const trimmed = value.trim();
  return trimmed ? trimmed.toLowerCase() : '';
}

function buildDeviceAuthPayloadV3(params) {
  const scopes = params.scopes.join(',');
  const token = params.token || '';
  const platform = normalizeDeviceAuthMetadata(params.platform);
  const deviceFamily = normalizeDeviceAuthMetadata(params.deviceFamily);
  return [
    'v3',
    params.deviceId,
    params.clientId,
    params.clientMode,
    params.role,
    scopes,
    String(params.signedAtMs),
    token,
    params.nonce,
    platform,
    deviceFamily,
  ].join('|');
}

function normalizeScopes(scopes) {
  if (!Array.isArray(scopes)) return [];
  return [...new Set(scopes.filter((scope) => typeof scope === 'string' && scope.trim()))].sort();
}

function loadBridgeDeviceAuthStore() {
  const store = readJsonFile(resolveBridgeDeviceAuthPath());
  if (!store || store.version !== 1 || typeof store.deviceId !== 'string') return null;
  return store;
}

function loadStoredBridgeDeviceToken(instanceKey, role) {
  const store = loadBridgeDeviceAuthStore();
  if (!store || store.deviceId !== BRIDGE_DEVICE_IDENTITY.deviceId) return null;
  const roleTokens = store.tokens?.[instanceKey];
  const entry = roleTokens && roleTokens[role];
  if (!entry || typeof entry.token !== 'string' || !entry.token.trim()) return null;
  return entry;
}

function storeBridgeDeviceToken(instanceKey, role, token, scopes) {
  if (!token || !token.trim()) return;
  const existing = loadBridgeDeviceAuthStore();
  const next = existing && existing.deviceId === BRIDGE_DEVICE_IDENTITY.deviceId
    ? existing
    : {
        version: 1,
        deviceId: BRIDGE_DEVICE_IDENTITY.deviceId,
        tokens: {},
      };
  next.tokens = next.tokens || {};
  next.tokens[instanceKey] = next.tokens[instanceKey] || {};
  next.tokens[instanceKey][role] = {
    token,
    role,
    scopes: normalizeScopes(scopes),
    updatedAtMs: Date.now(),
  };
  writeJsonFile(resolveBridgeDeviceAuthPath(), next);
}

const BRIDGE_DEVICE_IDENTITY = loadOrCreateBridgeDeviceIdentity();

// ---------------------------------------------------------------------------
// Gateway WebSocket Client
// ---------------------------------------------------------------------------
class GatewayClient {
  constructor(instanceId, host, port, token) {
    this.instanceId = instanceId;
    this.host = host;
    this.port = port;
    this.url = `ws://${host}:${port}`;
    this.token = token;
    this.deviceTokenStoreKey = `${instanceId}:${host}:${port}`;
    this.ws = null;
    this.connected = false;
    this.pending = new Map();          // reqId -> {resolve, reject, timer}
    this.chatWaiters = [];             // [{matchFn, resolve, reject, timer, _id}]
    this._reqId = 0;
    this._connecting = null;
    this._reconnectTimer = null;
    this._reconnectAttempt = 0;
    this._shouldReconnect = false;     // set to true once first connection succeeds
    this._consecutiveDnsFailures = 0;  // track DNS failures for diagnostics
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
      const ws = new WebSocket(this.url, {
        headers: { Origin: 'http://localhost:' + this.port },
      });
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
        for (const w of [...this.chatWaiters]) {
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

        // Log all incoming events for debugging
        if (msg.type === 'event') {
          console.log(`[bridge] Instance ${this.instanceId} event: ${msg.event}`);
        }

        // --- challenge-response auth ---
        if (msg.type === 'event' && msg.event === 'connect.challenge') {
          const role = 'operator';
          const storedDeviceToken = loadStoredBridgeDeviceToken(
            this.deviceTokenStoreKey,
            role,
          )?.token;
          const signedAtMs = Date.now();
          const signatureToken = this.token || storedDeviceToken || null;
          const devicePayload = buildDeviceAuthPayloadV3({
            deviceId: BRIDGE_DEVICE_IDENTITY.deviceId,
            clientId: BRIDGE_CLIENT_ID,
            clientMode: 'backend',
            role,
            scopes: BRIDGE_SCOPES,
            signedAtMs,
            token: signatureToken,
            nonce: msg.payload?.nonce || '',
            platform: 'linux',
            deviceFamily: BRIDGE_DEVICE_FAMILY,
          });
          const auth = { token: this.token };
          if (storedDeviceToken) {
            auth.deviceToken = storedDeviceToken;
          }
          this._send('connect', {
            minProtocol: 3,
            maxProtocol: 3,
            client: {
              id: BRIDGE_CLIENT_ID,
              displayName: 'OpenClaw Mesh Bridge',
              version: '1.0.0',
              platform: 'linux',
              deviceFamily: BRIDGE_DEVICE_FAMILY,
              mode: 'backend',
            },
            locale: 'en-US',
            role,
            scopes: BRIDGE_SCOPES,
            auth,
            device: {
              id: BRIDGE_DEVICE_IDENTITY.deviceId,
              publicKey: publicKeyRawBase64UrlFromPem(BRIDGE_DEVICE_IDENTITY.publicKeyPem),
              signature: signDevicePayload(BRIDGE_DEVICE_IDENTITY.privateKeyPem, devicePayload),
              signedAt: signedAtMs,
              nonce: msg.payload?.nonce || '',
            },
          }).then((hello) => {
            if (hello?.auth?.deviceToken) {
              storeBridgeDeviceToken(
                this.deviceTokenStoreKey,
                hello.auth.role || role,
                hello.auth.deviceToken,
                hello.auth.scopes || BRIDGE_SCOPES,
              );
            }
            if (Array.isArray(hello?.auth?.scopes) && hello.auth.scopes.length > 0) {
              console.log(
                `[bridge] Instance ${this.instanceId}: granted scopes ` +
                `${hello.auth.scopes.join(', ')}`
              );
              if (!hello.auth.scopes.includes('operator.write')) {
                console.warn(
                  `[bridge] Instance ${this.instanceId}: bridge is paired without ` +
                  `operator.write. Approve the pending mesh-bridge pairing request ` +
                  `to grant full relay access.`
                );
              }
            }
            clearTimeout(timeout);
            this.connected = true;
            this._shouldReconnect = true;
            this._reconnectAttempt = 0;
            this._connectedAt = Date.now();
            console.log(`[bridge] Connected to instance ${this.instanceId}`);
          }).then(() => {
            if (this.onStateChange) this.onStateChange(this.instanceId, true);
            resolve();
            // Modern gateways auto-deliver events to operator clients, but some
            // older builds needed an explicit subscription.  Keep this as a
            // best-effort legacy compatibility path without delaying connect.
            void this._subscribeLegacyEvents();
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
          console.log(`[bridge] Instance ${this.instanceId} chat event: state=${payload.state} sessionKey=${payload.sessionKey || '?'} runId=${payload.runId || '?'} terminal=${terminal} waiters=${this.chatWaiters.length}`);
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

  _send(method, params, timeoutMs = 30000) {
    return new Promise((resolve, reject) => {
      const id = String(++this._reqId);
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`Request timeout: ${method}`));
      }, timeoutMs);
      this.pending.set(id, { resolve, reject, timer });
      this.ws.send(JSON.stringify({ type: 'req', id, method, params }));
    });
  }

  async request(method, params, timeoutMs = 30000) {
    await this.ensureConnected();
    return this._send(method, params, timeoutMs);
  }

  _subscribeLegacyEvents() {
    const events = ['chat', 'chat.side_result'];
    return this._send('events.subscribe', { events }, 5000).catch(err => {
      console.warn(`[bridge] Instance ${this.instanceId}: events.subscribe failed: ${err.message} — trying events.listen fallback`);
      return this._send('events.listen', { events }, 5000).catch(() => {
        // Modern gateways auto-deliver events to operators, so these failures
        // are expected on newer builds.
        console.warn(`[bridge] Instance ${this.instanceId}: events.listen also failed — relying on auto-delivered events`);
      });
    });
  }

  /** Create a waiter for a terminal chat event tied to one request. */
  createChatWaiter(sessionKey, timeoutMs) {
    const waiter = {
      _id: crypto.randomUUID(),
      sessionKey,
      runId: null,
      settled: false,
      timer: null,
      resolve: null,
      reject: null,
      matchFn(payload) {
        if (waiter.runId && payload.runId) {
          return payload.runId === waiter.runId;
        }
        return payload.sessionKey === waiter.sessionKey;
      },
    };

    const removeWaiter = () => {
      const idx = this.chatWaiters.indexOf(waiter);
      if (idx !== -1) this.chatWaiters.splice(idx, 1);
    };

    const settle = (fn, value) => {
      if (waiter.settled) return;
      waiter.settled = true;
      if (waiter.timer) clearTimeout(waiter.timer);
      removeWaiter();
      fn(value);
    };

    const promise = new Promise((resolve, reject) => {
      waiter.resolve = (value) => settle(resolve, value);
      waiter.reject = (err) => settle(reject, err);
      waiter.timer = setTimeout(() => {
        waiter.reject(new Error(`Chat response timeout (${timeoutMs}ms)`));
      }, timeoutMs);
    });

    this.chatWaiters.push(waiter);

    return {
      promise,
      setRunId(runId) {
        waiter.runId = runId || null;
      },
      cancel() {
        waiter.resolve(null);
      },
    };
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
          this._consecutiveDnsFailures = 0;
          console.log(`[bridge] Reconnected to instance ${this.instanceId}`);
        })
        .catch((err) => {
          const isDns = err.code === 'ENOTFOUND' ||
            (err.message && err.message.includes('ENOTFOUND'));
          if (isDns) {
            this._consecutiveDnsFailures = (this._consecutiveDnsFailures || 0) + 1;
            console.warn(
              `[bridge] Reconnect to instance ${this.instanceId} failed: ` +
              `DNS lookup failed for ${this.host} (ENOTFOUND). ` +
              `The gateway container may not be on the mesh network.`
            );
            if (this._consecutiveDnsFailures === 3) {
              console.warn(
                `[bridge] Instance ${this.instanceId}: persistent DNS failure. ` +
                `To fix, run: docker network connect <mesh-network> ${this.host}`
              );
            }
          } else {
            this._consecutiveDnsFailures = 0;
            console.warn(`[bridge] Reconnect to instance ${this.instanceId} failed: ${err.message}`);
          }
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

  // If a client exists but isn't connected, let its reconnect cycle continue
  // rather than destroying and recreating it (which kills the backoff state).
  // Only create a new client if none exists at all.
  if (client) {
    // Client exists but not connected — try to connect it
    await client.ensureConnected();
    return client;
  }

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
    if (connected) {
      // Track when the instance came online so we can delay roster
      // injection until the gateway is fully ready.
      client._connectedAt = Date.now();
    }
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
let _rosterFollowUpTimer = null;

function scheduleRosterBroadcast() {
  if (_rosterTimer) clearTimeout(_rosterTimer);
  _rosterTimer = setTimeout(() => {
    _rosterTimer = null;
    broadcastRoster().catch(err => {
      console.error('[bridge] Roster broadcast failed:', err.message);
    });

    // Schedule a follow-up broadcast after newly connected instances have
    // had time to fully initialize (ROSTER_READY_DELAY_MS).  The first
    // broadcast skips them; this one will deliver the roster.
    if (!_rosterFollowUpTimer) {
      _rosterFollowUpTimer = setTimeout(() => {
        _rosterFollowUpTimer = null;
        broadcastRoster().catch(err => {
          console.error('[bridge] Follow-up roster broadcast failed:', err.message);
        });
      }, ROSTER_READY_DELAY_MS + 5000);
    }
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

  // Inject into every connected instance (best-effort, don't fail the whole batch).
  // Skip instances that connected recently — the gateway needs time to finish
  // initializing before it can safely handle chat.inject.  Injecting too early
  // can crash the gateway, creating a restart → reconnect → inject → crash loop.
  const now = Date.now();
  const results = await Promise.allSettled(
    entries.map(async ([id]) => {
      const client = clients.get(id);
      if (!client || !client.connected) return;
      const connectedAt = client._connectedAt || 0;
      if (now - connectedAt < ROSTER_READY_DELAY_MS) {
        console.log(`[bridge]   Instance #${id}: skipping roster (connected ${Math.round((now - connectedAt) / 1000)}s ago, waiting ${Math.round(ROSTER_READY_DELAY_MS / 1000)}s)`);
        return;
      }
      // Query active sessions and inject into the first one found
      const sessionsResult = await client.request('sessions.list', {});
      const sessions = sessionsResult?.sessions || sessionsResult || [];
      const sessionList = Array.isArray(sessions) ? sessions : [];
      if (sessionList.length === 0) {
        console.log(`[bridge]   Instance #${id}: no active sessions, skipping roster`);
        return;
      }
      const sessionKey = sessionList[0].key || sessionList[0].sessionKey || sessionList[0];
      await client.request('chat.inject', {
        sessionKey,
        message: roster,
        label: 'mesh-roster',
      });
      console.log(`[bridge]   Instance #${id}: roster delivered to session ${sessionKey}`);
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

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
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

function extractMessageRole(message) {
  if (!message || typeof message !== 'object') return '';
  return typeof message.role === 'string' ? message.role.toLowerCase() : '';
}

function extractMessageTimestamp(message) {
  if (!message || typeof message !== 'object') return 0;
  return typeof message.timestamp === 'number' ? message.timestamp : 0;
}

function extractAssistantMessageSignature(message) {
  if (extractMessageRole(message) !== 'assistant') return null;
  const text = extractText(message).trim();
  if (!text) return null;
  return {
    text,
    timestamp: extractMessageTimestamp(message),
  };
}

function findLatestAssistantMessage(messages, baseline) {
  if (!Array.isArray(messages)) return null;
  for (let i = messages.length - 1; i >= 0; i--) {
    const candidate = extractAssistantMessageSignature(messages[i]);
    if (!candidate) continue;
    if (!baseline) return candidate;
    if (candidate.timestamp > baseline.timestamp) return candidate;
    if (candidate.timestamp === baseline.timestamp && candidate.text !== baseline.text) {
      return candidate;
    }
    if (!candidate.timestamp && candidate.text !== baseline.text) return candidate;
  }
  return null;
}

async function snapshotLatestAssistantMessage(client, sessionKey) {
  try {
    const history = await client.request('chat.history', {
      sessionKey,
      limit: HISTORY_POLL_LIMIT,
    });
    return findLatestAssistantMessage(history?.messages, null);
  } catch (err) {
    console.warn(`[bridge] chat.history baseline failed for session ${sessionKey}: ${err.message}`);
    return null;
  }
}

async function fetchAssistantReplyFromHistory(client, sessionKey, baseline) {
  for (let attempt = 1; attempt <= HISTORY_POLL_ATTEMPTS; attempt++) {
    try {
      const history = await client.request('chat.history', {
        sessionKey,
        limit: HISTORY_POLL_LIMIT,
      });
      const latest = findLatestAssistantMessage(history?.messages, baseline);
      if (latest) return latest.text;
    } catch (err) {
      console.warn(
        `[bridge] chat.history fallback failed for session ${sessionKey} ` +
        `(attempt ${attempt}/${HISTORY_POLL_ATTEMPTS}): ${err.message}`
      );
    }
    if (attempt < HISTORY_POLL_ATTEMPTS) {
      await sleep(HISTORY_POLL_INTERVAL_MS);
    }
  }
  return '';
}

function formatAgentWaitError(result) {
  const status = typeof result?.status === 'string' ? result.status : 'error';
  const detail = typeof result?.error === 'string' && result.error.trim() ? `: ${result.error}` : '';
  return `agent ${status}${detail}`;
}

async function waitForBridgeReply({ client, sessionKey, runId, timeoutMs, waiter, historyBaseline }) {
  if (!runId) {
    const chatPayload = await waiter.promise;
    return extractText(chatPayload?.message);
  }

  waiter.setRunId(runId);

  const chatEventPromise = waiter.promise;
  const agentWaitPromise = client.request('agent.wait', {
    runId,
    timeoutMs,
  }, timeoutMs + AGENT_WAIT_TIMEOUT_PADDING_MS);

  const first = await Promise.race([
    chatEventPromise
      .then((payload) => ({ source: 'chat', payload }))
      .catch((error) => ({ source: 'chat-error', error })),
    agentWaitPromise
      .then((result) => ({ source: 'agent', result }))
      .catch((error) => ({ source: 'agent-error', error })),
  ]);

  if (first.source === 'chat') {
    waiter.cancel();
    return extractText(first.payload?.message);
  }

  if (first.source === 'chat-error') {
    let agentResult;
    try {
      agentResult = await agentWaitPromise;
    } catch {
      waiter.cancel();
      throw first.error;
    }
    if (agentResult?.status !== 'ok') {
      waiter.cancel();
      throw first.error;
    }
  } else if (first.source === 'agent-error') {
    try {
      const chatPayload = await chatEventPromise;
      waiter.cancel();
      return extractText(chatPayload?.message);
    } catch {
      waiter.cancel();
      throw first.error;
    }
  } else if (first.result?.status !== 'ok') {
    waiter.cancel();
    throw new Error(formatAgentWaitError(first.result));
  }

  try {
    const latePayload = await Promise.race([
      chatEventPromise,
      sleep(CHAT_EVENT_GRACE_MS).then(() => null),
    ]);
    waiter.cancel();
    if (latePayload) {
      return extractText(latePayload.message);
    }
  } catch {
    waiter.cancel();
  }

  const historyText = await fetchAssistantReplyFromHistory(client, sessionKey, historyBaseline);
  console.log(
    `[bridge] Recovered reply for run ${runId} from chat.history` +
    (historyText ? ` (${historyText.length} chars)` : ' (empty)')
  );
  return historyText;
}

function resolveRequestTimeout(rawTimeoutMs, fallbackMs) {
  if (typeof rawTimeoutMs !== 'number' || !Number.isFinite(rawTimeoutMs)) {
    return fallbackMs;
  }
  return Math.max(1000, Math.floor(rawTimeoutMs));
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
    //   { to: N, message: "...", sessionKey?: "...", timeoutMs?: 120000 }
    if (req.method === 'POST' && req.url === '/send') {
      const body = await readBody(req);
      const { to, message, sessionKey, timeoutMs: rawTimeoutMs } = body;

      if (!to || !message) {
        return sendJson(res, 400, {
          ok: false,
          error: 'Missing "to" (instance number) or "message"',
        });
      }

      const client = await getClient(to);
      const key = sessionKey || 'main';
      const timeoutMs = resolveRequestTimeout(rawTimeoutMs, RESPONSE_TIMEOUT);
      const idempotencyKey = crypto.randomUUID();
      const historyBaseline = await snapshotLatestAssistantMessage(client, key);

      // Strategy: try chat.send with a long timeout — many gateways return
      // the AI response synchronously in the res payload.  If the gateway
      // returns a short ack instead (no message), use a durable wait path:
      // chat events first, agent.wait second, chat.history as the final fallback.
      console.log(`[bridge] /send: sending to instance ${to}, session=${key}, timeout=${timeoutMs}ms`);

      const waiter = client.createChatWaiter(key, timeoutMs);

      const sendResult = await client.request('chat.send', {
        sessionKey: key,
        message: String(message),
        idempotencyKey,
      }, timeoutMs);

      console.log(`[bridge] /send: chat.send returned:`, JSON.stringify(sendResult).slice(0, 500));

      // Check if the response is already in the sendResult
      const syncText = extractText(sendResult?.message || sendResult?.response);
      if (syncText) {
        waiter.cancel();
        console.log(`[bridge] /send: got synchronous response (${syncText.length} chars)`);
        return sendJson(res, 200, {
          ok: true,
          from: to,
          sessionKey: key,
          response: syncText,
        });
      }

      console.log(
        `[bridge] /send: no inline response, waiting for completion ` +
        `(runId=${sendResult?.runId || '?'})...`
      );
      const text = await waitForBridgeReply({
        client,
        sessionKey: key,
        runId: sendResult?.runId,
        timeoutMs,
        waiter,
        historyBaseline,
      });

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
    //     to: M, message: "...", toSessionKey?: "...", timeoutMs?: 120000 }
    if (req.method === 'POST' && req.url === '/relay') {
      const body = await readBody(req);
      const { from, fromSessionKey, to, message, toSessionKey, timeoutMs: rawTimeoutMs } = body;

      if (!from || !fromSessionKey || !to || !message) {
        return sendJson(res, 400, {
          ok: false,
          error: 'Missing required fields: from, fromSessionKey, to, message',
        });
      }

      // Send to the target instance
      const targetClient = await getClient(to);
      const tKey = toSessionKey || 'main';
      const timeoutMs = resolveRequestTimeout(rawTimeoutMs, RESPONSE_TIMEOUT);
      const idempotencyKey = crypto.randomUUID();
      const historyBaseline = await snapshotLatestAssistantMessage(targetClient, tKey);
      const waiter = targetClient.createChatWaiter(tKey, timeoutMs);

      const sendResult = await targetClient.request('chat.send', {
        sessionKey: tKey,
        message: String(message),
        idempotencyKey,
      }, timeoutMs);

      console.log(`[bridge] /relay: chat.send returned:`, JSON.stringify(sendResult).slice(0, 500));

      // Check if the response is already in the sendResult
      let text = extractText(sendResult?.message || sendResult?.response);
      if (text) {
        waiter.cancel();
        console.log(`[bridge] /relay: got synchronous response (${text.length} chars)`);
      } else {
        console.log(
          `[bridge] /relay: no inline response, waiting for completion ` +
          `(runId=${sendResult?.runId || '?'})...`
        );
        text = await waitForBridgeReply({
          client: targetClient,
          sessionKey: tKey,
          runId: sendResult?.runId,
          timeoutMs,
          waiter,
          historyBaseline,
        });
      }

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
        const isDns = err.code === 'ENOTFOUND' ||
          (err.message && err.message.includes('ENOTFOUND'));
        if (isDns) {
          const inst = config.instances[id];
          console.warn(
            `[bridge] Pre-connect to instance ${id} failed: ` +
            `DNS lookup failed for ${inst ? inst.host : '?'} (ENOTFOUND). ` +
            `Container may not be on the mesh network or not running yet.`
          );
        } else {
          console.warn(`[bridge] Pre-connect to instance ${id} failed: ${err.message}`);
        }
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
