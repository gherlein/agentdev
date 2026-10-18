#!/bin/bash
# config.sh - layered configuration for agentdev.
#
# Resolution order (first found wins per key; CLI flags, applied by the launcher
# AFTER this runs, always win):
#   1. ./.agentdev.toml        (per-project, committable)
#   2. ~/.agentdev/config.toml (user)
#   3. built-in defaults
#
# Populates these globals, which the launcher may then override from CLI flags:
#   AGENT_NAME IMAGE LOCALDEV_UNUSED
#   PROFILES_ROOT CLEAN_ROOT MEMORY_ROOT DEFAULT_MODE
#   TEMPLATE_SOURCE TEMPLATE_STRATEGY  (TEMPLATE_INCLUDE is an array)
#   AUTH_MODE WS_ISOLATION WS_TRUST
#
# Requires: $LIBDIR set to this file's directory (for toml.py), python3.

PROJECT_CONFIG="./.agentdev.toml"
USER_CONFIG="${AGENTDEV_HOME:-$HOME/.agentdev}/config.toml"

# expand_tilde PATH - replace a leading ~ with $HOME. Leaves other paths intact.
expand_tilde() {
  local p="$1"
  case "$p" in
    "~") printf '%s\n' "$HOME" ;;
    "~/"*) printf '%s\n' "$HOME/${p#\~/}" ;;
    *) printf '%s\n' "$p" ;;
  esac
}

_toml() { python3 "$LIBDIR/toml.py" "$@"; }

# cfg_scalar KEY DEFAULT - first value found across project then user config,
# else DEFAULT. Tilde-expanded on the way out.
cfg_scalar() {
  local key="$1" def="$2" val
  if val=$(_toml get "$PROJECT_CONFIG" "$key" 2>/dev/null); then
    expand_tilde "$val"; return 0
  fi
  if val=$(_toml get "$USER_CONFIG" "$key" 2>/dev/null); then
    expand_tilde "$val"; return 0
  fi
  expand_tilde "$def"
}

# cfg_list KEY - prints list items from project then user config (no default).
cfg_list() {
  local key="$1"
  if _toml list "$PROJECT_CONFIG" "$key" 2>/dev/null; then return 0; fi
  _toml list "$USER_CONFIG" "$key" 2>/dev/null
}

load_config() {
  # Validate any config files that exist before reading them (fail-closed).
  local f
  for f in "$PROJECT_CONFIG" "$USER_CONFIG"; do
    if [[ -f "$f" ]] && ! _toml check "$f"; then
      echo "Error: invalid config file: $f" >&2
      exit 1
    fi
  done

  AGENT_NAME=$(cfg_scalar "agent.name" "claude")
  IMAGE=$(cfg_scalar "agent.image" "ghcr.io/gherlein/agentdev:latest")

  PROFILES_ROOT=$(cfg_scalar "profile.profiles_root" "$HOME/.agentdev/profiles")
  CLEAN_ROOT=$(cfg_scalar "profile.clean_root" "$HOME/.cache/agentdev/clean")
  MEMORY_ROOT=$(cfg_scalar "profile.memory_root" "$HOME/.agentdev/memory")
  DEFAULT_MODE=$(cfg_scalar "profile.default_mode" "clean")

  TEMPLATE_SOURCE=$(cfg_scalar "template.source" "$SELFDIR/templates/default")
  TEMPLATE_STRATEGY=$(cfg_scalar "template.strategy" "copy")

  # include list: configured, else a sensible built-in default.
  TEMPLATE_INCLUDE=()
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] && TEMPLATE_INCLUDE+=("$line")
  done < <(cfg_list "template.include")
  if [[ ${#TEMPLATE_INCLUDE[@]} -eq 0 ]]; then
    TEMPLATE_INCLUDE=("CLAUDE.md" "settings.json" "hooks" "skills" ".mcp.json")
  fi

  AUTH_MODE=$(cfg_scalar "auth.mode" "auto")
  WS_ISOLATION=$(cfg_scalar "workspace.isolation" "mount")
  WS_TRUST=$(cfg_scalar "workspace.trust" "skip-permissions")
}
