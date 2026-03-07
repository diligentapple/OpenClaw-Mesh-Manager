#!/usr/bin/env bash
set -euo pipefail

cat <<'EOF'
OpenClaw Multi-Instance Manager -- Command Reference
=====================================================

INSTANCE LIFECYCLE
------------------

  openclaw-new N
      Create a new OpenClaw instance #N with automatic ports (N8789/N8790).
      Options:
        --pull          Pull the latest Docker image before creating
        --port PORT     Use a custom API port (WS port = PORT+1)
      Example:
        openclaw-new 3
        openclaw-new --pull --port 9000 6

  openclaw-onboard N
      Run the interactive onboarding wizard for instance #N.
      This sets up your config (API keys, Telegram bot, etc.).
      Must be run after openclaw-new.

  openclaw-update N
      Pull the latest OpenClaw Docker image and recreate instance #N.

  openclaw-delete N
      Delete instance #N (container, compose file, and data directory).
      Prompts for confirmation (type DELETE). Also cleans up Tailscale
      Serve if it was active for that instance.

RUNNING COMMANDS
----------------

  openclawN [command...]
      Shortcut to run commands inside instance #N's container.
      Without arguments, opens an interactive shell.
      Examples:
        openclaw1                                  (interactive shell)
        openclaw1 pairing approve telegram ABC123  (OpenClaw CLI command)
        openclaw2 node --version                   (system command)

  openclaw-exec N [command...]
      Same as openclawN, using the explicit form.
      Example: openclaw-exec 1 cat /app/config.json

MONITORING
----------

  openclaw-list
      Show all running OpenClaw containers with their port mappings.

  Health check:
      curl http://127.0.0.1:N8789/health

  Logs:
      docker logs -f openclawN-gateway

REMOTE ACCESS (via Tailscale)
-----------------------------

  openclaw-remote N
      Enable remote dashboard access for instance #N via Tailscale.
      Configures LAN binding, allowed origins, host firewall, and
      sets up tailscale serve for HTTPS.

  openclaw-remote N --off
      Disable remote access. Reverts config to loopback-only and
      stops Tailscale Serve.

  openclaw-remote N --status
      Show remote access status: config state, Tailscale info,
      dashboard health, paired/pending devices, firewall state.

  openclaw-remote N --approve
      Approve pending device pairing requests (interactive).

  openclaw-remote N --approve --yes
      Auto-approve all pending devices without confirmation.

HELP
----

  openclaw-help
      Show this help message.

PORT SCHEME
-----------

  Instance 1: API 18789, WS 18790
  Instance 2: API 28789, WS 28790
  Instance 3: API 38789, WS 38790
  ...
  Instance N: API N8789, WS N8790  (instances 6+ require --port)

DIRECTORY LAYOUT
----------------

  ~/openclawN/           Compose file for instance N
  ~/.openclawN/          Persistent data for instance N
    openclaw.json        Main configuration
    nodes/ or devices/   Device pairing data
    workspace/           Working directory

MORE INFO
---------

  https://github.com/diligentapple/OpenClaw-Multi-Instance-Manager
EOF
