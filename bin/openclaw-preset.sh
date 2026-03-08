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

  # --- API key ---
  echo ""
  local api_env_var=""
  case "$provider" in
    openrouter) api_env_var="OPENROUTER_API_KEY" ;;
    anthropic)  api_env_var="ANTHROPIC_API_KEY" ;;
    openai)     api_env_var="OPENAI_API_KEY" ;;
  esac
  read -r -p "${provider} API key: " api_key
  if [[ -z "$api_key" ]]; then
    echo "Warning: empty API key. Set ${api_env_var} in the container environment or edit the preset later."
  fi

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

  # --- Tailscale remote access ---
  local bind="loopback"
  local tailscale_mode="off"
  if command -v tailscale >/dev/null 2>&1; then
    echo ""
    read -r -p "Enable Tailscale remote access? [y/N]: " ts_choice
    if [[ "${ts_choice,,}" == "y" ]]; then
      bind="lan"
      tailscale_mode="off"  # openclaw-remote handles the actual serve setup
      echo "  Network binding set to 'lan', insecure auth enabled."
    fi
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

  local auth_block='{}'
  if [[ -n "$api_key" ]]; then
    auth_block=$(jq -n \
      --arg provider "$provider" \
      --arg key "$api_key" \
      '{
        auth: {
          profiles: {
            "\($provider):default": {
              provider: $provider,
              mode: "api_key",
              apiKey: $key
            }
          }
        }
      }')
  fi

  local base_json
  base_json=$(jq -n \
    --arg bind "$bind" \
    --arg provider "$provider" \
    --arg model "$model" \
    --arg tailscale_mode "$tailscale_mode" \
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
          maxConcurrent: 4,
          subagents: { maxConcurrent: 8 }
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
        tailscale: { mode: $tailscale_mode, resetOnExit: false },
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
          allowInsecureAuth: true
        }
      },
      plugins: { entries: {} },
      meta: {
        lastTouchedVersion: "2026.3.2",
        lastTouchedAt: "{{TIMESTAMP}}"
      }
    }')

  # Merge optional blocks
  local json="$base_json"
  if [[ -n "$api_key" ]]; then
    json=$(echo "$json" "$auth_block" | jq -s '.[0] * .[1]')
  fi
  if [[ "$tg_enabled" == true ]]; then
    json=$(echo "$json" "$tg_block" | jq -s '.[0] * .[1]')
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
