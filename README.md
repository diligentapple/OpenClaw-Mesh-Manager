# OpenClaw Multi-Instance Manager

Easily create, manage, delete multiple [OpenClaw](https://github.com/openclaw/openclaw) Docker instances on a single machine with deterministic naming, ports, and data directories.

This tool wraps a community OpenClaw Docker image (`ghcr.io/phioranex/openclaw-docker:latest`) to make it easy to run multiple isolated instances on a single VPS.

## Prerequisites

- Docker Engine (20.10+)
- Docker Compose plugin (`docker compose`) or legacy `docker-compose`
- `curl` (for one-liner install)
Docker will be auto installed in this script (if not present on the machine).

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

### Step 1: Create an instance

```bash
openclaw-new N
```

Example: `openclaw-new 3` creates instance #3.

**(Optional) To force pulling the latest OpenClaw image before creating:**

```bash
openclaw-new --pull N
```

### Step 2: Onboarding (required after creating)

```bash
openclaw-onboard N
```

## Useful Commands
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
Note: Data is preserved, but may cause compatibility issues -> updating using this method not recommanded

```bash
openclaw-update N
```

### List running instances

```bash
openclaw-list
```

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

## Firewall / Reverse Proxy

Ports are bound to `0.0.0.0` by default. For production, consider:

- Binding to `127.0.0.1` and using a reverse proxy (nginx, caddy)
- Configuring firewall rules (`ufw`, `iptables`) to restrict access

## Credits

This project manages instances of the [OpenClaw Docker image](https://github.com/phioranex/openclaw-docker) (`ghcr.io/phioranex/openclaw-docker`) by [@phioranex](https://github.com/phioranex).

## License

MIT License. See [LICENSE](LICENSE).
