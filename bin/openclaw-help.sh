#!/usr/bin/env bash
set -euo pipefail

cat <<'EOF'
OpenClaw Multi-Instance Manager -- Command Reference
=====================================================

INSTANCE LIFECYCLE
------------------

  openclaw-new [options] N|N-M [--preset NAME] [--mesh NAME]
      Create one or more OpenClaw instances with automatic ports (N8789/N8790).
      N must be a positive integer (1, 2, 3, …). Names or letters are not allowed.
      Options:
        --pull          Pull the latest Docker image before creating
        --port PORT     Use a custom API port (WS port = PORT+1)
        -o, --onboard   Start onboarding wizard immediately after creation
        --preset NAME   Skip onboarding, apply a preset config
        --mesh NAME     Join a named mesh network (default: openclaw-net)
      Examples:
        openclaw-new 3                        (single instance)
        openclaw-new 2-4                      (range of instances)
        openclaw-new 2-4 --preset default     (range + auto-configure)
        openclaw-new -o 3                     (create + onboard in one step)
        openclaw-new --pull --port 9000 6
        openclaw-new 1 --mesh research         (join the "research" mesh)

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

  openclaw-watchdog [options] N|all
      Monitor gateways and auto-restart frozen ones.
      A gateway is frozen if it produces no log output within the
      silence threshold (default: 10 minutes).
      Options:
        --install          Install as a cron job (runs every 5 minutes)
        --uninstall        Remove the cron job
        --threshold MINS   Minutes of silence before restart (default: 10)
        --dry-run          Report without restarting
      Examples:
        openclaw-watchdog all                Check all instances
        openclaw-watchdog --install all      Install cron for all instances
        openclaw-watchdog --uninstall        Remove cron job

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

MESH NETWORKING
---------------

  openclaw-mesh list
      List all mesh networks and their member instances.
      Shows bridge status (running/stopped) per network and
      container status per instance.

  openclaw-mesh start [NETWORK]
      Create a shared Docker network, discover all running instances,
      generate a bridge config, and start the bridge container.
      The bridge is also started automatically by openclaw-new
      when creating a new instance (no manual start needed).
      After this, every instance agent can reach the bridge at
      http://openclaw-bridge:3000 (default) or
      http://openclaw-bridge-NAME:3000 (named network).
      On start, a roster announcement is injected into each
      instance listing all network members.

  openclaw-mesh stop [NETWORK]
      Stop the bridge container and remove the network (if empty).

  openclaw-mesh status [NETWORK]
      Show network, bridge, and instance connectivity status.

  openclaw-mesh refresh [NETWORK]
      Re-discover instances (e.g. after creating new ones),
      regenerate the bridge config, restart the bridge, and
      announce the updated roster to all instances.
      This is called AUTOMATICALLY by openclaw-new.

  openclaw-mesh join N [NETWORK]
      Move an existing instance to a different mesh network.
      Updates the instance's config, reconnects the container,
      and refreshes both the old and new network's bridge.
      Examples:
        openclaw-mesh join 3 research   Move instance #3 to "research"
        openclaw-mesh join 5            Move instance #5 to default network

  openclaw-mesh leave N
      Remove an instance from its current mesh network.
      Disconnects the container, clears the mesh config,
      and refreshes the old network's bridge.
      Example:
        openclaw-mesh leave 3           Remove instance #3 from its mesh

  Named networks:
      By default all instances join the openclaw-net network.
      Use --mesh NAME with openclaw-new to assign instances
      to isolated networks. Each named network gets its own
      bridge container and config directory.
      Examples:
        openclaw-new 1 --mesh research
        openclaw-new 2 --mesh research
        openclaw-mesh status research
        openclaw-mesh stop research

      To add an existing instance to a network after creation:
        openclaw-mesh join 3 research

  Instance metadata:
      Each instance can have a name and description stored in
        ~/.openclawN/.mesh-meta
      Line 1 = name, Line 2 = description.  Example:
        echo -e "Research Agent\\nSpecializes in web research" \\
          > ~/.openclaw2/.mesh-meta
      These are included in the roster announcement and the
      /instances API response.

  Bridge HTTP API (from inside any instance container):
    GET  /health      Bridge health check
    GET  /instances   List registered instances (with name/description)
    POST /send        Send message, wait for agent response
                      Body: {"to": N, "message": "...", "sessionKey": "..."}
    POST /inject      Inject assistant message into a session
                      Body: {"instance": N, "sessionKey": "...", "message": "..."}
    POST /relay       Send to B, inject response into A's session
                      Body: {"from": N, "fromSessionKey": "...",
                             "to": M, "message": "...", "toSessionKey": "..."}

  Example (from instance 1's agent via exec/curl):
    curl -s -X POST http://openclaw-bridge:3000/send \
      -H 'Content-Type: application/json' \
      -d '{"to": 2, "message": "Summarize recent logs"}'

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
    .mesh-network        Current mesh network assignment
    .mesh-meta           Instance name + description (for mesh roster)
    nodes/ or devices/   Device pairing data
    workspace/           Working directory
  ~/.openclaw-mesh/      Default mesh bridge config & data
    config.json          Discovered instances, tokens, metadata
    bridge.js            Bridge server (copied from share dir)
  ~/.openclaw-mesh/NAME/ Named mesh bridge config & data
  /usr/local/share/openclaw-manager/
    bridge/              Bridge source (bridge.js)
    presets/             Preset config files
    templates/           Docker compose template

MORE INFO
---------

  https://github.com/diligentapple/OpenClaw-Mesh-Manager
EOF
