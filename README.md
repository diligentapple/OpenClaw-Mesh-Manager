# OpenClaw Multi-Instance Manager
Easily create, manage, and delete multiple [OpenClaw](https://github.com/openclaw/openclaw) Docker instances on a single machine with deterministic naming, ports, data directories, and convenient shortcut commands for quick container access.

## Prerequisites

- **Linux** (this tool is Linux-only; on Windows use WSL2, on macOS use a Linux VM)
- Docker Engine (20.10+)
- Docker Compose plugin (`docker compose`) or legacy `docker-compose`
- `curl` (for one-liner install)
Docker will be auto installed in this script (if not present on the machine).

## Install

### Option A: One-liner (no git required)

```bash
curl -fsSL https://raw.githubusercontent.com/diligentapple/OpenClaw-Multi-Instance-Manager/main/bootstrap.sh | sudo bash
```

### Option B: Clone and install

```bash
git clone https://github.com/diligentapple/OpenClaw-Multi-Instance-Manager.git
cd OpenClaw-Multi-Instance-Manager
sudo bash install.sh
```

### After installing

The installer adds your user to the `docker` group so you can run commands without `sudo`. For this to take effect, either:

```bash
newgrp docker   # apply in current shell
```

or log out and back in.

## Create Container

### Step 1: Create an instance

```bash
openclaw-new N
```

Example: `openclaw-new 3` creates instance #3.

Create and immediately run onboarding:

```bash
openclaw-new -o 3
```

Create a range of instances (#2 - #4):

```bash
openclaw-new 2-4
```

To force pulling the latest image before creating (recommended):

```bash
openclaw-new --pull N
```

### Step 2: Onboarding

If you didn't use `--preset` (optional function, see below), run the interactive onboarding wizard:

```bash
openclaw-onboard N
```

### Step 3: Activate Telegram bot

After onboarding with a Telegram channel (recommended), send a message to your bot on Telegram. You will see a pairing request in the container logs:

```
OpenClaw: access not configured.
Your Telegram user id: XXXXXXXXXX
Pairing code: XXXXXX
Ask the bot owner to approve with:
  openclaw pairing approve telegram XXXXXX
```

Approve the pairing from your host machine using the instance shortcut:

```bash
openclaw1 pairing approve telegram XXXXXX
```

Replace `1` with your instance number and `XXXXXX` with the actual pairing code shown in the logs.

### Presets (optional, skip onboarding for batch setup)

Presets let you create fully configured instances without running the interactive onboarding wizard. On first use, you'll be prompted for your LLM API key which is cached for future runs.

```bash
# Create a single instance with the default preset
openclaw-new 3 --preset default

# Create multiple instances at once
openclaw-new 2-4 --preset default

# Use the remote preset (LAN binding for Tailscale)
openclaw-new 2-4 --preset remote
```

Built-in presets:

| Preset    | Binding   | Description                        |
|-----------|-----------|------------------------------------|
| `default` | loopback  | Local access only                  |
| `remote`  | lan       | LAN binding for Tailscale access   |

#### Managing presets

```bash
# List available presets
openclaw-preset list

# Show a preset's contents
openclaw-preset show default

# Interactively create a custom preset
openclaw-preset create
```

`openclaw-preset create` prompts for:
- AI provider (OpenRouter, Anthropic, OpenAI) and API key
- Primary model
- Telegram bot integration (optional)
- Tailscale remote access (if Tailscale is installed)

### Health check / logs

```bash
openclaw-health N
openclaw-logs N
```

### Run commands inside an instance

When you create an instance, a shortcut `openclawN` is automatically created. Use it to run commands inside the container without needing `docker exec`:

```bash
# Directly run a single command
openclaw1 node --version
openclaw2 cat /app/config.json
openclawN pairing approve telegram XXXXXX

# Open an interactive shell in instance 1
openclaw1
```

The longer form also works:

```bash
openclaw-exec 1 node --version
```

### Update an instance

```bash
openclaw-update N
```

This backs up your config, pulls the latest Docker image, recreates the container, runs config migration (`doctor`), restarts the gateway, and verifies health. If the health check fails, check logs with `openclaw-logs N --tail 20`.

### List running instances

```bash
openclaw-list
```

### Help

```bash
openclaw-help
```

Shows a complete reference of all available commands with usage details, options, and examples.

### Delete an instance

```bash
openclaw-delete N
openclaw-delete 2-4    # delete a range
```

You will be prompted to type `DELETE` to confirm.

## Port Scheme

Each instance N gets deterministic ports:

| Instance | API Port  | WS Port   |
|----------|-----------|-----------|
| 1        | 18789     | 18790     |
| 2        | 28789     | 28790     |
| 3        | 38789     | 38790     |
| ...      | N8789     | N8790     |

## Directory Layout

| Path                          | Purpose                                    |
|-------------------------------|--------------------------------------------|
| `~/openclawN/`                | Compose file + `.env` for instance N       |
| `~/.openclawN/`               | Persistent data for instance N             |
| `~/.openclawN/openclaw.json`  | Main configuration                         |
| `~/.openclawN/workspace/`     | Working directory                          |

## Command Reference

| Command | Description |
|---------|-------------|
| `openclaw-new N\|N-M [--preset NAME]` | Create instance(s) |
| `openclaw-delete N\|N-M` | Delete instance(s) |
| `openclaw-onboard N` | Run onboarding wizard |
| `openclaw-preset [list\|show\|create]` | Manage config presets |
| `openclaw-update N` | Update instance (backup, pull, migrate, verify) |
| `openclaw-exec N [cmd...]` | Run command in container |
| `openclawN [cmd...]` | Shortcut for openclaw-exec |
| `openclaw-remote N` | Enable Tailscale remote access |
| `openclaw-logs N` | Follow container logs |
| `openclaw-health N` | Health check |
| `openclaw-list` | List all instances with ports |
| `openclaw-mesh start\|stop\|status\|refresh` | Manage inter-instance mesh network |
| `openclaw-help` | Full command reference |

Run `openclaw-help` for detailed usage of every command.

## Notes

- Uses the official `ghcr.io/openclaw/openclaw` image (gateway + CLI services)
- Each instance runs a gateway container and can launch a CLI container on-demand
- 1 instance = 1 gateway container
- Instances don't interfere with each other
- Instances can communicate via the mesh network (`openclaw-mesh start`)
- Safe to run many on one VPS
- Creating an instance with a number that already exists is blocked -- you must delete first
- `openclaw-new N` without `--pull` uses the locally cached image if one exists; use `openclaw-new --pull N` to ensure you get the latest version

## Remote Dashboard Access (via Tailscale)

Access your OpenClaw dashboard from any device on your Tailscale network with automatic HTTPS.

### Prerequisites

- [Tailscale](https://tailscale.com/download/linux) installed and connected (`sudo tailscale up`)
- MagicDNS enabled in [Tailscale admin console](https://login.tailscale.com/admin/dns) (recommended for HTTPS)
- `jq` (auto-installed if missing)

### Enable remote access

```bash
openclaw-remote N
```

This configures the instance for LAN access, sets up allowed origins, configures the host firewall for Tailscale traffic, and starts `tailscale serve` for HTTPS.

### Approve device pairing

When a browser connects for the first time, OpenClaw may require device approval:

```bash
openclaw-remote N --approve       # interactive confirmation
openclaw-remote N --approve --yes # auto-approve without confirmation
```

### Check status

```bash
openclaw-remote N --status
```

Shows config state, Tailscale info, dashboard health, paired/pending devices, and firewall state.

### Disable remote access

```bash
openclaw-remote N --off
```

Reverts config to loopback-only and stops Tailscale Serve. Firewall rules are left in place (harmless).

### Multiple instances

Only one instance can use `https://<hostname>/` via Tailscale Serve at a time. Other instances remain accessible via their direct IP and port (`http://<tailscale-ip>:<port>/`).

### Supported platforms

The firewall auto-configuration handles ufw, firewalld, iptables, and nftables. Cloud-level firewalls (AWS Security Groups, GCP VPC rules, etc.) do not affect Tailscale traffic.

### Troubleshooting

- **"Tailscale is not connected"** -- Run `sudo tailscale up`
- **HTTPS not working** -- Enable MagicDNS at https://login.tailscale.com/admin/dns; certificates may take up to 30 seconds on first use
- **Dashboard rejects connection** -- Check `openclaw-remote N --status` to verify `gateway.bind` is `lan` and origins are set
- **"pairing required"** -- Run `openclaw-remote N --approve`

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
openclaw-mesh start     # Create network, discover instances, launch bridge, announce roster
openclaw-mesh stop      # Stop bridge, remove network if empty
openclaw-mesh status    # Show network, bridge, and connection status
openclaw-mesh refresh   # Re-discover instances, restart bridge, re-announce roster
```

New instances are **automatically discovered**: when you run `openclaw-new` while the mesh is running, it triggers `openclaw-mesh refresh` behind the scenes — the new instance is added to the config, connected to the network, and all instances receive an updated roster announcement.

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

- **Docker network** (`openclaw-net`): A shared external network connecting all instance containers and the bridge
- **Bridge container** (`openclaw-bridge`): Runs the same OpenClaw Docker image with a custom entrypoint (`bridge.js`). Uses the `ws` module already present in the image.
- **Config**: Auto-generated at `~/.openclaw-mesh/config.json` from instance tokens and metadata
- **No host ports exposed**: The bridge listens only on the Docker network (port 3000). Agents reach it by container name.
- **Roster announcements**: On start/refresh, the bridge injects a member list into each instance's main session so every agent knows the full topology

## Firewall / Reverse Proxy

Ports are bound to `0.0.0.0` by default. For production, consider:

- Binding to `127.0.0.1` and using a reverse proxy (nginx, caddy)
- Configuring firewall rules (`ufw`, `iptables`) to restrict access

## Credits

This project manages instances of the official [OpenClaw Docker image](https://github.com/openclaw/openclaw) (`ghcr.io/openclaw/openclaw`).

## License

MIT License. See [LICENSE](LICENSE).
