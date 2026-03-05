# OpenClaw Multi-Instance Manager

Manage multiple OpenClaw Docker instances on a single machine with deterministic naming, ports, and data directories.

## Prerequisites

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

## Usage

### Create an instance

```bash
openclaw-new N
```

Example: `openclaw-new 3` creates instance #3.

### Onboard / health check / logs

```bash
# Health check
curl http://127.0.0.1:38789/health

# Logs
docker logs -f openclaw3-gateway
```

### Update an instance (pull latest image and recreate)

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

## Firewall / Reverse Proxy

Ports are bound to `0.0.0.0` by default. For production, consider:

- Binding to `127.0.0.1` and using a reverse proxy (nginx, caddy)
- Configuring firewall rules (`ufw`, `iptables`) to restrict access

## License

MIT License. See [LICENSE](LICENSE).
