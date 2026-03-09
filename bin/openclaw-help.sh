#!/usr/bin/env bash
set -euo pipefail

cat <<'EOF'
OpenClaw Multi-Instance Manager -- Command Reference
=====================================================

INSTANCE LIFECYCLE
------------------

  openclaw-new [options] N|N-M [--preset NAME]
      Create one or more OpenClaw instances with automatic ports (N8789/N8790).
      Options:
        --pull          Pull the latest Docker image before creating
        --port PORT     Use a custom API port (WS port = PORT+1)
        -o, --onboard   Start onboarding wizard immediately after creation
        --preset NAME   Skip onboarding, apply a preset config
      Examples:
        openclaw-new 3                        (single instance)
        openclaw-new 2-4                      (range of instances)
        openclaw-new 2-4 --preset default     (range + auto-configure)
        openclaw-new -o 3                     (create + onboard in one step)
        openclaw-new --pull --port 9000 6

  openclaw-onboard N
      Run the interactive onboarding wizard for instance #N.
      This sets up your config (API keys, Telegram bot, etc.).
      Must be run after openclaw-new (not needed if --preset was used).

  openclaw-update N
      Update instance #N to the latest OpenClaw Docker image.
      Steps: backs up config, pulls latest image, recreates container,
      runs config migration (doctor), restarts gateway, verifies health.

  openclaw-delete N|N-M
      Delete instance(s) (container, compose file, and data directory).
      Supports ranges (e.g. openclaw-delete 2-4). Prompts once for
      confirmation (type DELETE). Also cleans up Tailscale Serve.

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

  openclaw-health N
      Health check for instance #N.

  openclaw-logs N [--tail N]
      Follow container logs for instance #N.
      Extra flags are passed through to docker logs (e.g. --tail 50).

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

PRESETS
-------

  openclaw-preset list
      List available presets.

  openclaw-preset show NAME
      Show the contents of a preset.

  openclaw-preset create
      Interactively create a new preset (prompts for settings).

  Built-in presets:
    default   Loopback binding, insecure auth enabled
    remote    LAN binding, insecure auth enabled (for Tailscale)

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
