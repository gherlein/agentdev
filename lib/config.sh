#!/bin/bash
# config.sh - layered JSON configuration for agentdev.
#
# Resolution order (first found wins per key; CLI flags, applied by the launcher
# AFTER this runs, always win):
#   1. project config         ./agentdev-config.json, or the -c/--config path
#   2. user config            ~/.agentdev/config.json   (honors $AGENTDEV_HOME)
#   3. built-in defaults
#
# JSON is the only config format: every CLI flag has a matching key, grouped and
# consistently ordered (see README / DESIGN §5). Keys are dotted paths into the
# grouped object, e.g. "workspace.workdir" -> {"workspace": {"workdir": …}}.
#
# Populates these globals, which the launcher may then override from CLI flags:
#   AGENT_NAME IMAGE
#   PROFILES_ROOT CLEAN_ROOT MEMORY_ROOT DEFAULT_MODE
#   CFG_PROFILE_NAME CFG_MEMORY_STORE CFG_KEEP
#   TEMPLATE_SOURCE TEMPLATE_STRATEGY  (TEMPLATE_INCLUDE is an array)
#   AUTH_MODE WS_ISOLATION WS_TRUST WS_WORKDIR
#   NET_MODE NET_LOG NET_MITM           (NET_ALLOW is an array)
#   CONFIRM_RW WS_MOUNT_MODE            (CFG_RW_ALLOW is an array)
#   SANDBOX_SSH
#
# Requires: $LIBDIR set to this file's directory (for jsoncfg.py), python3.

# The project config path and whether it was requested explicitly (-c/--config).
# The launcher's pre-parse in main() sets these before load_config runs; defaults
# here keep the library usable when sourced directly (tests).
JSON_CONFIG="${JSON_CONFIG:-./agentdev-config.json}"
JSON_CONFIG_EXPLICIT="${JSON_CONFIG_EXPLICIT:-no}"
USER_CONFIG="${AGENTDEV_HOME:-$HOME/.agentdev}/config.json"

# expand_tilde PATH - replace a leading ~ with $HOME. Leaves other paths intact.
expand_tilde() {
  local p="$1"
  case "$p" in
    "~") printf '%s\n' "$HOME" ;;
    "~/"*) printf '%s\n' "$HOME/${p#\~/}" ;;
    *) printf '%s\n' "$p" ;;
  esac
}

_json() { python3 "$LIBDIR/jsoncfg.py" "$@"; }

# cfg_scalar KEY DEFAULT - first value found in the project then user config, else
# DEFAULT. Tilde-expanded on the way out.
cfg_scalar() {
  local key="$1" def="$2" val
  if [[ -f "$JSON_CONFIG" ]] && val=$(_json get "$JSON_CONFIG" "$key" 2>/dev/null); then
    expand_tilde "$val"; return 0
  fi
  if [[ -f "$USER_CONFIG" ]] && val=$(_json get "$USER_CONFIG" "$key" 2>/dev/null); then
    expand_tilde "$val"; return 0
  fi
  expand_tilde "$def"
}

# cfg_list KEY - prints list items from the project then user config (no default).
# The first config that defines the key wins outright (no merging).
cfg_list() {
  local key="$1"
  if [[ -f "$JSON_CONFIG" ]] && _json list "$JSON_CONFIG" "$key" 2>/dev/null; then return 0; fi
  [[ -f "$USER_CONFIG" ]] && _json list "$USER_CONFIG" "$key" 2>/dev/null
}

# _read_list KEY ARRAYNAME - fill the named array from cfg_list (skips blank lines).
_read_list() {
  local key="$1" __arr="$2" line
  eval "$__arr=()"
  while IFS= read -r line; do
    [[ -n "$line" ]] && eval "$__arr+=(\"\$line\")"
  done < <(cfg_list "$key")
}

load_config() {
  # Validate every config file that exists before reading it (fail-closed). An
  # explicit -c/--config that points at a missing file is itself an error.
  if [[ "$JSON_CONFIG_EXPLICIT" == yes && ! -f "$JSON_CONFIG" ]]; then
    echo "Error: config file not found: $JSON_CONFIG" >&2
    exit 1
  fi
  local f
  for f in "$JSON_CONFIG" "$USER_CONFIG"; do
    if [[ -f "$f" ]] && ! _json check "$f"; then
      echo "Error: invalid config file: $f" >&2
      exit 1
    fi
  done

  # --- agent ----------------------------------------------------------------
  AGENT_NAME=$(cfg_scalar "agent.name" "claude")
  IMAGE=$(cfg_scalar "agent.image" "ghcr.io/gherlein/agentdev:latest")

  # --- profile --------------------------------------------------------------
  DEFAULT_MODE=$(cfg_scalar "profile.default_mode" "clean")
  CFG_PROFILE_NAME=$(cfg_scalar "profile.name" "")
  CFG_MEMORY_STORE=$(cfg_scalar "profile.memory_store" "default")
  CFG_KEEP=$(cfg_scalar "profile.keep" "false")
  PROFILES_ROOT=$(cfg_scalar "profile.profiles_root" "$HOME/.agentdev/profiles")
  CLEAN_ROOT=$(cfg_scalar "profile.clean_root" "$HOME/.cache/agentdev/clean")
  MEMORY_ROOT=$(cfg_scalar "profile.memory_root" "$HOME/.agentdev/memory")

  # --- template -------------------------------------------------------------
  TEMPLATE_SOURCE=$(cfg_scalar "template.source" "$SELFDIR/templates/default")
  TEMPLATE_STRATEGY=$(cfg_scalar "template.strategy" "copy")
  _read_list "template.include" TEMPLATE_INCLUDE
  if [[ ${#TEMPLATE_INCLUDE[@]} -eq 0 ]]; then
    TEMPLATE_INCLUDE=("CLAUDE.md" "settings.json" "hooks" "skills" ".mcp.json")
  fi

  # --- auth -----------------------------------------------------------------
  AUTH_MODE=$(cfg_scalar "auth.mode" "auto")

  # --- workspace ------------------------------------------------------------
  WS_ISOLATION=$(cfg_scalar "workspace.isolation" "mount")
  WS_TRUST=$(cfg_scalar "workspace.trust" "skip-permissions")
  # The entry folder: where the container's shell starts (the bash cwd). Empty or
  # "." means the workspace root. Relative paths resolve under the workspace mount;
  # an absolute path is used as-is. CLI --workdir overrides this.
  WS_WORKDIR=$(cfg_scalar "workspace.workdir" "")

  # --- network (sandbox / eval policy; all off by default) ------------------
  NET_MODE=$(cfg_scalar "network.mode" "off")         # off | allowlist | none
  NET_LOG=$(cfg_scalar "network.log" "false")
  NET_MITM=$(cfg_scalar "network.mitm" "false")
  _read_list "network.allow" NET_ALLOW

  # --- mounts ---------------------------------------------------------------
  WS_MOUNT_MODE=$(cfg_scalar "mounts.workspace" "rw")  # rw | ro
  CONFIRM_RW=$(cfg_scalar "mounts.confirm_rw" "false")
  _read_list "mounts.rw_allow" CFG_RW_ALLOW

  # --- sandbox --------------------------------------------------------------
  SANDBOX_SSH=$(cfg_scalar "sandbox.ssh" "true")
}
