# OpenClaw Multi-Instance Manager

Manage multiple [OpenClaw](https://github.com/phioranex/openclaw-docker) Docker instances on a single machine with deterministic naming, ports, and data directories.

This tool wraps the official OpenClaw Docker image (`ghcr.io/phioranex/openclaw-docker:latest`) to make it easy to run multiple isolated instances on a single VPS.

## Prerequisites

- **Linux** (this tool is Linux-only; on Windows use WSL2, on macOS use a Linux VM)
- Docker Engine (20.10+)
- Docker Compose plugin (`docker compose`) or legacy `docker-compose`
- `curl` (for one-liner install)

## Install

### Option A: Clone and install

```bash
git clone https://github.com/diligentapple/OpenClaw-Multi-Instance-Manager.git
cd OpenClaw-Multi-Instance-Manager
sudo bash install.sh
```

### Option B: One-liner (no git required)

```bash
curl -fsSL https://raw.githubusercontent.com/diligentapple/OpenClaw-Multi-Instance-Manager/main/bootstrap.sh | sudo bash
```

### After installing

The installer adds your user to the `docker` group so you can run commands without `sudo`. For this to take effect, either:

```bash
newgrp docker   # apply in current shell
```

or log out and back in.

## Usage

### Create an instance

```bash
openclaw-new N
```

Example: `openclaw-new 3` creates instance #3.

To force pulling the latest image before creating:

```bash
openclaw-new --pull N
```

### Onboarding (required after creating)

```bash
openclaw-onboard N
```

### Activate Telegram bot

After onboarding with a Telegram channel, send a message to your bot on Telegram. You will see a pairing request in the container logs:

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

### Health check / logs

```bash
# Health check
curl http://127.0.0.1:N8789/health

# Logs
docker logs -f openclawN-gateway
```

### Run commands inside an instance

When you create an instance, a shortcut `openclawN` is automatically created. Use it to run commands inside the container without needing `docker exec`:

```bash
# Open an interactive shell in instance 1
openclaw1

# Run a single command
openclaw1 node --version
openclaw2 cat /app/config.json
```

The longer form also works:

```bash
openclaw-exec 1 node --version
```

### Update an instance (pull latest image and recreate)

```bash
openclaw-update N
```

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

| Path              | Purpose                          |
|-------------------|----------------------------------|
| `~/openclawN/`    | Compose file for instance N      |
| `~/.openclawN/`   | Persistent data for instance N   |

## Notes

- 1 instance = 1 container
- Instances don't interfere with each other
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

## Firewall / Reverse Proxy

Ports are bound to `0.0.0.0` by default. For production, consider:

- Binding to `127.0.0.1` and using a reverse proxy (nginx, caddy)
- Configuring firewall rules (`ufw`, `iptables`) to restrict access

## Credits

This project manages instances of the [OpenClaw Docker image](https://github.com/phioranex/openclaw-docker) (`ghcr.io/phioranex/openclaw-docker`) by [@phioranex](https://github.com/phioranex).

## License

MIT License. See [LICENSE](LICENSE).
