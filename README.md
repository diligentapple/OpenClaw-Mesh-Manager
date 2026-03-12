# OpenClaw Mesh Manager

Easily run a fleet of [OpenClaw](https://github.com/openclaw/openclaw) AI agents on a single machine via Docker and let them talk to each other over a mesh network — with optional remote access via Tailscale.

通过 Docker 在单台机器上轻松运行数个 OpenClaw AI Agent，并允许 Agent 通过局域网相互通信。还可以选配 Tailscale 远程访问 Dashboard 操作面板。

## Quick Start

### 1. Install

```bash
# One-liner (no git required)
curl -fsSL https://raw.githubusercontent.com/diligentapple/OpenClaw-Mesh-Manager/main/bootstrap.sh | sudo bash

# Or clone and install
git clone https://github.com/diligentapple/OpenClaw-Mesh-Manager.git
cd OpenClaw-Mesh-Manager
sudo bash install.sh
```

After installing, activate the `docker` group in your current shell:

```bash
newgrp docker
```

> **Prerequisites:** Linux (use WSL2 on Windows, a VM on macOS). Docker is auto-installed if not present.

### 2. Create instances

```bash
openclaw-new 1              # create instance #1 (only numbers allowed, for easier ports mapping)
openclaw-new 2-4            # create instance #2 - #4, as many as you need 
```

Each instance gets deterministic ports (`N8789` / `N8790`) and isolated data directories.

To place instances on a named mesh network:

```bash
openclaw-new 1 --mesh research
openclaw-new 2 --mesh research
```

Without `--mesh`, all instances join the default `openclaw-net` network. The mesh bridge is started automatically when the first instance is created.

For batch setup with a preset (skips interactive onboarding):

```bash
openclaw-new 1-4 --preset default
openclaw-new 1-4 --preset default --mesh research   # batch + named network
```

### 3. Onboard (if no preset was used)

```bash
openclaw-onboard 1
```

The wizard configures your API keys, model, and optionally Telegram. Repeat for each instance. (Automate / Batch onboard with --preset flag, see below)

### 4. Use the mesh

The mesh bridge starts automatically when you create instances. From inside any container the agent can:

```bash
# Send a message to instance 2 and get the response
curl -s -X POST http://openclaw-bridge:3000/send \
  -H 'Content-Type: application/json' \
  -d '{"to": 2, "message": "Summarize today's research"}'

# List all instances on the mesh
curl -s http://openclaw-bridge:3000/instances
```

To add an existing instance to a different mesh after creation:

```bash
openclaw-mesh join 3 research   # move instance #3 to the "research" network
openclaw-mesh leave 3           # remove instance #3 from its mesh entirely
```

### 5. Access the dashboard remotely using Tailscale (optional)

If [Tailscale](https://tailscale.com/download/linux) is installed:

```bash
openclaw-remote 1
```

This gives you an HTTPS dashboard at `https://<hostname>/` from any device on your Tailnet. 
```bash
openclaw-list    # list all the OpenClaw instances with their tailscale url (if any)
```
---

## Mesh Networking

The mesh lets instances collaborate. Each instance runs as an independent AI agent; the mesh bridge routes messages between them over a shared Docker network.

### How it works

1. `openclaw-new` places every instance on a Docker network (default: `openclaw-net`). Using `--mesh NAME` targets a specific network instead.
2. The mesh bridge is automatically started (or refreshed) each time an instance is created. You can also manage it manually with `openclaw-mesh start/stop/refresh`.
3. Agents send and receive messages via the bridge's HTTP API.
4. To move an existing instance to a different network, use `openclaw-mesh join N NETWORK`. To remove it from the mesh entirely, use `openclaw-mesh leave N`.

### Named networks

You can isolate groups of instances into separate mesh networks:

```bash
# Create instances on the "research" network (bridge auto-starts)
openclaw-new 1 --mesh research
openclaw-new 2 --mesh research

# Create instances on the "ops" network
openclaw-new 3 --mesh ops
```

To move an existing instance to a network after creation:

```bash
openclaw-mesh join 3 research    # moves instance #3 to "research"
openclaw-mesh leave 3            # removes instance #3 from the mesh entirely
```

`join` updates the instance's config, reconnects the container, and refreshes both the old and new network's bridge. `leave` disconnects the container, clears the mesh config, and refreshes the old bridge.

Network names may only contain letters, numbers, hyphens, and underscores.

### Mesh commands

| Command | Description |
|---------|-------------|
| `openclaw-mesh list` | List all networks and their member instances |
| `openclaw-mesh start [NETWORK]` | Discover instances, launch bridge |
| `openclaw-mesh stop [NETWORK]` | Stop the bridge (and remove the network if empty) |
| `openclaw-mesh status [NETWORK]` | Show connected instances, bridge health |
| `openclaw-mesh refresh [NETWORK]` | Re-discover instances and restart the bridge |
| `openclaw-mesh join N [NETWORK]` | Move an existing instance to a mesh network |
| `openclaw-mesh leave N` | Remove an instance from its current mesh network |

The bridge is started automatically by `openclaw-new`. These commands are for manual management.

### Bridge API

All endpoints are accessible from inside any container on the mesh.

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/health` | Bridge health check |
| `GET` | `/instances` | List all registered instances |
| `POST` | `/send` | Send a message and wait for the agent's response |
| `POST` | `/inject` | Inject an assistant message into a session |
| `POST` | `/relay` | Send to B, inject the response back into A's session |

### Instance metadata

Give instances human-readable names by creating a `.mesh-meta` file:

```bash
printf 'Researcher\nSearches the web and summarizes papers\n' > ~/.openclaw1/.mesh-meta
```

Line 1 is the name, line 2 is the description. The mesh roster announcement includes this info.

---

## Remote Access (Tailscale)

Access the OpenClaw dashboard from any device on your Tailscale network with automatic HTTPS.

### Enable

```bash
openclaw-remote N
```

This binds the instance to LAN, configures allowed origins, opens the firewall for Tailscale traffic, and starts `tailscale serve`.

### Approve device pairing

When a browser connects for the first time, OpenClaw may require device approval:

```bash
openclaw-remote N --approve        # interactive
openclaw-remote N --approve --yes  # auto-approve
```

### Check status / disable

```bash
openclaw-remote N --status   # show Tailscale info, dashboard health, firewall state
openclaw-remote N --off      # revert to loopback-only, stop Tailscale Serve
```

### Notes

- Only one instance can use `https://<hostname>/` at a time. Others are still reachable at `http://<tailscale-ip>:<port>/`.
- Firewall auto-configuration supports ufw, firewalld, iptables, and nftables. Cloud firewalls (AWS SGs, GCP VPC, etc.) don't affect Tailscale traffic.
- Enable [MagicDNS](https://login.tailscale.com/admin/dns) in the Tailscale admin console for HTTPS certificates.

---

## Setup Guide Details

### Presets

Presets create fully configured instances without interactive onboarding. On first use you'll be prompted for your LLM API key (cached for future runs).

```bash
openclaw-new 3 --preset default    # local access only
openclaw-new 3 --preset remote     # LAN binding for Tailscale
openclaw-new 1-4 --preset default  # batch create
```

| Preset | Binding | Description |
|--------|---------|-------------|
| `default` | loopback | Local access only |
| `remote` | lan | LAN binding for Tailscale |

Manage presets:

```bash
openclaw-preset list      # list available presets
openclaw-preset show default
openclaw-preset create    # interactive: provider, model, Telegram, Tailscale
```

### Telegram bot activation

After onboarding with Telegram, send a message to your bot. The logs will show a pairing request:

```
Your Telegram user id: XXXXXXXXXX
Pairing code: XXXXXX
```

Approve from the host:

```bash
openclaw1 pairing approve telegram XXXXXX
```

### Container shortcuts

Every instance gets an `openclawN` shortcut:

```bash
openclaw1                                  # interactive shell
openclaw1 node --version                   # run a command
openclaw1 pairing approve telegram XXXXXX  # OpenClaw CLI
openclaw-exec 1 node --version             # longer form
```

### Update an instance

```bash
openclaw-update N
```

Backs up config, pulls the latest image, recreates the container, runs config migration, and verifies health.

### Monitoring

```bash
openclaw-health N          # health check
openclaw-logs N            # follow container logs
openclaw-list              # list all instances with ports and status
```

### Watchdog

Auto-restart frozen gateways (no log output within a threshold):

```bash
openclaw-watchdog 1              # check instance 1
openclaw-watchdog all            # check all running instances
openclaw-watchdog --install all  # install as a cron job (every 5 min)
openclaw-watchdog --uninstall    # remove cron job
```

### Delete instances

```bash
openclaw-delete 1       # delete instance 1
openclaw-delete 2-4     # delete a range
```

You'll be prompted to type `DELETE` to confirm.

---

## Reference

### Port scheme

| Instance | API Port | WS Port |
|----------|----------|---------|
| 1 | 18789 | 18790 |
| 2 | 28789 | 28790 |
| 3 | 38789 | 38790 |
| N | N8789 | N8790 |

Use `--port PORT` for a custom port (WS = PORT+1). Instances 6+ prompt for a port.

### Directory layout

| Path | Purpose |
|------|---------|
| `~/openclawN/` | Compose file + `.env` |
| `~/.openclawN/` | Persistent data |
| `~/.openclawN/openclaw.json` | Main configuration |
| `~/.openclawN/workspace/` | Agent working directory |
| `~/.openclawN/.mesh-network` | Mesh network assignment |
| `~/.openclawN/.mesh-meta` | Instance name & description |
| `~/.openclaw-mesh/` | Mesh bridge config & state |

### All commands

| Command | Description |
|---------|-------------|
| `openclaw-new N\|N-M [--preset NAME] [--mesh NAME]` | Create instance(s). N must be a positive integer |
| `openclaw-onboard N` | Run onboarding wizard |
| `openclaw-mesh start\|stop\|status\|refresh\|join [NETWORK]` | Manage mesh network |
| `openclaw-remote N [--off\|--status\|--approve]` | Tailscale remote access |
| `openclawN [cmd...]` | Run command in container |
| `openclaw-exec N [cmd...]` | Longer form of the above |
| `openclaw-health N` | Health check |
| `openclaw-logs N` | Follow container logs |
| `openclaw-list` | List all instances |
| `openclaw-update N` | Update instance |
| `openclaw-watchdog N\|all` | Monitor & auto-restart frozen gateways |
| `openclaw-preset [list\|show\|create]` | Manage config presets |
| `openclaw-delete N\|N-M` | Delete instance(s) |
| `openclaw-help` | Full command reference |

### Troubleshooting

| Problem | Fix |
|---------|-----|
| Tailscale not connected | `sudo tailscale up` |
| HTTPS not working | Enable MagicDNS at https://login.tailscale.com/admin/dns |
| Dashboard rejects connection | `openclaw-remote N --status` — check `gateway.bind` is `lan` |
| Device pairing required | `openclaw-remote N --approve` |
| Mesh bridge won't start | Ensure instances are running (`openclaw-list`) then `openclaw-mesh start` |
| `non-string key in networks` | Network name must be alphanumeric / hyphens / underscores, not a bare number |

### Notes

- Uses the official `ghcr.io/openclaw/openclaw` Docker image
- 1 instance = 1 gateway container, fully isolated
- Safe to run many instances on a single VPS
- Creating an instance with an existing number is blocked — delete first
- `openclaw-new --pull N` ensures the latest image; without `--pull` the local cache is used

## Mesh Networking (Inter-Instance Communication)

Let your OpenClaw instances talk to each other — including through Telegram. The mesh creates a shared Docker network and runs a lightweight bridge container that translates HTTP requests from agents into WebSocket messages to other instance gateways.

### How it works

```
Telegram user → Instance 1 agent
  ↓ (agent runs curl via exec tool)
  http://openclaw-bridge:3000/send  →  Instance 2 gateway (WebSocket)
  ↓                                          ↓
  Instance 2 agent processes and responds
  ↓
  Bridge returns response as HTTP body
  ↓
Instance 1 agent receives response → replies to Telegram user
```

The `/relay` endpoint goes further: it sends your message to Instance B, waits for the response, and automatically injects it back into your Telegram conversation on Instance A via `chat.inject`.

### Quick start

```bash
# 1. Start the mesh (creates network, discovers instances, launches bridge)
openclaw-mesh start

# 2. From any instance's agent, talk to another instance:
curl -s -X POST http://openclaw-bridge:3000/send \
  -H 'Content-Type: application/json' \
  -d '{"to": 2, "message": "What are you working on?"}'
```

The agent uses its built-in `exec` tool to run `curl` commands against the bridge. No extra configuration is needed inside the container — the bridge is reachable at `http://openclaw-bridge:3000` on the shared Docker network.

### Named networks

By default all instances join the `openclaw-net` network. You can create **isolated mesh networks** so groups of instances only see each other:

```bash
# Create instances on a "research" network
openclaw-new 1 --mesh research
openclaw-new 2 --mesh research

# Create instances on a "devops" network
openclaw-new 3 --mesh devops
openclaw-new 4 --mesh devops

# Start each network's mesh separately
openclaw-mesh start research
openclaw-mesh start devops
```

Each named network gets:
- Its own Docker network (e.g. `research`, `devops`)
- Its own bridge container (e.g. `openclaw-bridge-research`, `openclaw-bridge-devops`)
- Its own config directory (`~/.openclaw-mesh/research/`, `~/.openclaw-mesh/devops/`)
- Isolated roster announcements — instances only see members of their own network

The network name is stored in `~/.openclawN/.mesh-network`. Instances on the `research` network reach their bridge at `http://openclaw-bridge-research:3000`, and `devops` instances at `http://openclaw-bridge-devops:3000`.

All `openclaw-mesh` commands accept an optional `[NETWORK]` argument:

```bash
openclaw-mesh status research    # status of the research network
openclaw-mesh refresh devops     # refresh the devops network
openclaw-mesh stop research      # stop the research mesh
```

Omitting the network name operates on the default `openclaw-net` network.

### Bridge API endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/health` | Bridge health check |
| `GET` | `/instances` | List registered instances and connection status |
| `POST` | `/send` | Send a message to an instance, wait for the agent's response |
| `POST` | `/inject` | Inject an assistant message into a session (broadcasts to Telegram) |
| `POST` | `/relay` | Send to instance B, inject response back into instance A's session |

#### POST /send

```json
{
  "to": 2,
  "message": "Summarize your recent activity",
  "sessionKey": "main"
}
```

`sessionKey` is optional (defaults to `"main"`). Returns the agent's response text.

#### POST /inject

```json
{
  "instance": 1,
  "sessionKey": "agent:main:telegram:direct:123456789",
  "message": "Here's the report from Instance 2: ...",
  "label": "mesh-relay"
}
```

Injects a message into the specified session. If the session is a Telegram session, the message is delivered to the Telegram chat.

#### POST /relay

```json
{
  "from": 1,
  "fromSessionKey": "agent:main:telegram:direct:123456789",
  "to": 2,
  "message": "Generate a status report",
  "toSessionKey": "main"
}
```

Combines `/send` + `/inject`: sends the message to instance 2, waits for the response, then injects it into instance 1's Telegram session.

### Telegram integration

The mesh works seamlessly with Telegram sessions:

1. A Telegram user sends a message to Instance 1's bot
2. Instance 1's agent decides it needs input from Instance 2
3. The agent runs `curl http://openclaw-bridge:3000/send -d '{"to":2,"message":"..."}'` via its `exec` tool
4. The bridge connects to Instance 2's gateway over WebSocket, sends the message, and waits for the response
5. The response is returned to Instance 1's agent, which incorporates it into its reply to the Telegram user

For automatic relay (the response appears directly in Telegram without the agent needing to forward it), use the `/relay` endpoint with the Telegram session key (`agent:main:telegram:direct:{telegram_user_id}`).

### Management commands

```bash
openclaw-mesh list                # List all networks and their member instances
openclaw-mesh start [NETWORK]     # Create network, discover instances, launch bridge, announce roster
openclaw-mesh stop [NETWORK]      # Stop bridge, remove network if empty
openclaw-mesh status [NETWORK]    # Show network, bridge, and connection status
openclaw-mesh refresh [NETWORK]   # Re-discover instances, restart bridge, re-announce roster
openclaw-mesh join N [NETWORK]    # Move an existing instance to a mesh network
openclaw-mesh leave N             # Remove an instance from its current mesh network
```

The mesh bridge is **started automatically** by `openclaw-new`. If the bridge is already running, it refreshes. Either way the new instance is added to the config, connected to the network, and all instances receive an updated roster announcement.

To add or remove instances after creation:

```bash
openclaw-mesh join 3 research    # moves instance #3 from its current network to "research"
openclaw-mesh join 5              # moves instance #5 to the default network
openclaw-mesh leave 3            # removes instance #3 from its mesh entirely
```

### Instance discovery & announcements

When the mesh starts (or refreshes), every instance receives an **announcement message** injected into its `main` session listing all network members:

```
[OpenClaw Mesh Network] Connected instances:
  • Instance 1 (Coding Agent) — Handles programming tasks
  • Instance 2 (Research Agent) — Specializes in web research
  • Instance 3 (Ops Agent) — Infrastructure and DevOps

To message another instance: curl -s -X POST http://openclaw-bridge:3000/send ...
To see all instances: curl -s http://openclaw-bridge:3000/instances
```

This way each agent **knows who else is on the network** and what they do.

#### Instance metadata

Give each instance a name and description by creating a `.mesh-meta` file:

```bash
echo -e "Research Agent\nSpecializes in web research and summarization" \
  > ~/.openclaw2/.mesh-meta
```

Line 1 = name, Line 2 = description. These appear in:
- The roster announcement sent to all instances
- The `GET /instances` API response

Instances without a `.mesh-meta` file default to "Instance N" with no description.

### Architecture

- **Docker network**: A shared external network connecting instance containers and the bridge. Default: `openclaw-net`. Named networks use the network name directly (e.g. `research`, `devops`).
- **Bridge container**: Runs the same OpenClaw Docker image with a custom entrypoint (`bridge.js`). Default: `openclaw-bridge`. Named networks: `openclaw-bridge-{name}`.
- **Config**: Auto-generated at `~/.openclaw-mesh/config.json` (default) or `~/.openclaw-mesh/{name}/config.json` (named) from instance tokens and metadata.
- **No host ports exposed**: The bridge listens only on the Docker network (port 3000). Agents reach it by container name.
- **Roster announcements**: On start/refresh, the bridge injects a member list into each instance's main session so every agent knows the full topology.

## Firewall / Reverse Proxy

Ports are bound to `0.0.0.0` by default. For production, consider:

- Binding to `127.0.0.1` and using a reverse proxy (nginx, caddy)
- Configuring firewall rules (`ufw`, `iptables`) to restrict access

## Credits

This project manages instances of the official [OpenClaw Docker image](https://github.com/openclaw/openclaw) (`ghcr.io/openclaw/openclaw`).

## License

MIT License. See [LICENSE](LICENSE).
