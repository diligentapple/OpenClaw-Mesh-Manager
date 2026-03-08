#!/usr/bin/env bash
set -euo pipefail

PRESET_DIR="${OPENCLAW_MGR_PRESETS:-/usr/local/share/openclaw-manager/presets}"

usage() {
  echo "Usage: openclaw-preset [list | show NAME | create]"
  echo ""
  echo "Commands:"
  echo "  list              List available presets"
  echo "  show NAME         Show contents of a preset"
  echo "  create            Interactively create a new preset"
  echo ""
  echo "Preset directory: $PRESET_DIR"
}

list_presets() {
  if [[ ! -d "$PRESET_DIR" ]]; then
    echo "No presets directory found at $PRESET_DIR"
    return
  fi
  local found=false
  for f in "$PRESET_DIR"/*.json; do
    [[ -f "$f" ]] || continue
    found=true
    echo "  $(basename "$f" .json)"
  done
  if [[ "$found" == false ]]; then
    echo "  (no presets found)"
  fi
}

show_preset() {
  local name="$1"
  local file="${PRESET_DIR}/${name}.json"
  if [[ ! -f "$file" ]]; then
    echo "Preset '$name' not found."
    echo ""
    echo "Available presets:"
    list_presets
    return 1
  fi
  echo "Preset: $name"
  echo "File:   $file"
  echo "---"
  cat "$file"
}

create_preset() {
  echo "Create a new OpenClaw preset"
  echo "============================"
  echo ""
  echo "Presets are full openclaw.json templates. Per-instance values"
  echo "(ports, auth tokens) are filled in automatically by openclaw-new."
  echo ""

  # Name
  local name=""
  while [[ -z "$name" ]]; do
    read -r -p "Preset name (e.g. 'mysetup'): " name
    name=$(echo "$name" | tr -cd 'a-zA-Z0-9_-')
    if [[ -z "$name" ]]; then
      echo "Invalid name. Use alphanumeric characters, hyphens, or underscores."
    fi
  done

  local file="${PRESET_DIR}/${name}.json"
  if [[ -f "$file" ]]; then
    read -r -p "Preset '$name' already exists. Overwrite? [y/N]: " overwrite
    if [[ "${overwrite,,}" != "y" ]]; then
      echo "Aborted."
      return 1
    fi
  fi

  # --- Network binding ---
  echo ""
  echo "Network binding:"
  echo "  1) loopback  - Local access only (default)"
  echo "  2) lan       - Allow LAN/Tailscale remote access"
  read -r -p "Choice [1]: " bind_choice
  local bind="loopback"
  if [[ "$bind_choice" == "2" ]]; then
    bind="lan"
  fi

  # --- AI provider ---
  echo ""
  echo "AI provider:"
  echo "  1) openrouter  (default - supports many models)"
  echo "  2) anthropic"
  echo "  3) openai"
  read -r -p "Choice [1]: " provider_choice
  local provider="openrouter"
  case "$provider_choice" in
    2) provider="anthropic" ;;
    3) provider="openai" ;;
  esac

  # --- Model ---
  echo ""
  local default_model=""
  case "$provider" in
    openrouter)  default_model="openrouter/anthropic/claude-haiku-4.5" ;;
    anthropic)   default_model="anthropic/claude-haiku-4.5" ;;
    openai)      default_model="openai/gpt-4o-mini" ;;
  esac
  read -r -p "Primary model [$default_model]: " model_input
  local model="${model_input:-$default_model}"

  # --- Telegram ---
  echo ""
  echo "Telegram bot integration:"
  read -r -p "Enable Telegram? [y/N]: " tg_choice
  local tg_enabled=false
  local tg_token=""
  if [[ "${tg_choice,,}" == "y" ]]; then
    tg_enabled=true
    read -r -p "Bot token (from @BotFather): " tg_token
    if [[ -z "$tg_token" ]]; then
      echo "Warning: empty bot token. You can edit the preset later."
    fi
  fi

  # --- Max concurrent ---
  echo ""
  read -r -p "Max concurrent agents [4]: " max_concurrent_input
  local max_concurrent="${max_concurrent_input:-4}"

  # --- Allow insecure auth ---
  echo ""
  read -r -p "Allow insecure auth (HTTP without HTTPS)? [Y/n]: " insecure_choice
  local insecure=true
  if [[ "${insecure_choice,,}" == "n" ]]; then
    insecure=false
  fi

  # --- Build JSON ---
  local tg_block='{}'
  if [[ "$tg_enabled" == true ]]; then
    tg_block=$(jq -n --arg token "$tg_token" '{
      channels: {
        telegram: {
          enabled: true,
          dmPolicy: "pairing",
          botToken: $token,
          groupPolicy: "allowlist",
          streaming: "partial"
        }
      },
      plugins: {
        entries: {
          telegram: { enabled: true }
        }
      }
    }')
  fi

  local base_json
  base_json=$(jq -n \
    --arg bind "$bind" \
    --arg provider "$provider" \
    --arg model "$model" \
    --argjson insecure "$insecure" \
    --argjson maxConcurrent "$max_concurrent" \
    '{
      wizard: {
        lastRunAt: "{{TIMESTAMP}}",
        lastRunVersion: "2026.3.2",
        lastRunCommand: "preset",
        lastRunMode: "local"
      },
      auth: {
        profiles: {
          "\($provider):default": {
            provider: $provider,
            mode: "api_key"
          }
        }
      },
      agents: {
        defaults: {
          model: { primary: $model },
          models: { ($model): {} },
          workspace: "/home/node/.openclaw/workspace",
          compaction: { mode: "safeguard" },
          maxConcurrent: $maxConcurrent,
          subagents: { maxConcurrent: ($maxConcurrent * 2) }
        }
      },
      tools: { profile: "messaging" },
      messages: { ackReactionScope: "group-mentions" },
      commands: {
        native: "auto",
        nativeSkills: "auto",
        restart: true,
        ownerDisplay: "raw"
      },
      session: { dmScope: "per-channel-peer" },
      gateway: {
        port: 18789,
        mode: "local",
        bind: $bind,
        auth: { mode: "token", token: "{{TOKEN}}" },
        tailscale: { mode: "off", resetOnExit: false },
        nodes: {
          denyCommands: [
            "camera.snap", "camera.clip", "screen.record",
            "contacts.add", "calendar.add", "reminders.add", "sms.send"
          ]
        },
        controlUi: {
          allowedOrigins: [
            "http://localhost:{{API_PORT}}",
            "http://127.0.0.1:{{API_PORT}}"
          ],
          allowInsecureAuth: $insecure
        }
      },
      plugins: { entries: {} },
      meta: {
        lastTouchedVersion: "2026.3.2",
        lastTouchedAt: "{{TIMESTAMP}}"
      }
    }')

  # Merge telegram block if enabled
  local json
  if [[ "$tg_enabled" == true ]]; then
    json=$(echo "$base_json" "$tg_block" | jq -s '.[0] * .[1]')
  else
    json="$base_json"
  fi

  echo ""
  echo "Preview:"
  echo "$json" | jq .
  echo ""
  read -r -p "Save preset '$name'? [Y/n]: " confirm
  if [[ "${confirm,,}" == "n" ]]; then
    echo "Aborted."
    return 1
  fi

  sudo tee "$file" > /dev/null <<< "$json"
  sudo chmod 644 "$file"
  echo ""
  echo "Saved: $file"
  echo "Use it with: openclaw-new 2-4 --preset $name"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

CMD="${1:-}"

case "$CMD" in
  list|ls)
    echo "Available presets:"
    list_presets
    ;;
  show|cat)
    if [[ -z "${2:-}" ]]; then
      echo "Usage: openclaw-preset show NAME"
      exit 1
    fi
    show_preset "$2"
    ;;
  create|new)
    create_preset
    ;;
  -h|--help|"")
    usage
    ;;
  *)
    echo "Unknown command: $CMD"
    usage
    exit 1
    ;;
esac
