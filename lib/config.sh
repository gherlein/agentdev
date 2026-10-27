#!/bin/bash
# config.sh - the single JSON configuration file for agentdev.
#
# One file defines a launch: ./agentdev-config.json, or the -c/--config path. There
# is no user-level layer and no environment-variable input: a key the file omits
# takes its built-in default, and nothing else. The file is validated against the
# schema in jsoncfg.py before any key is read; an unknown key, a wrong type, or a
# value outside its enum aborts (fail-closed).
#
# Relative paths in the file resolve against the directory that holds the file, so
# its meaning does not depend on where agentdev is launched from.
#
# Populates these globals:
#   CONFIG_PRESENT CONFIG_DIR
#   AGENT_NAME IMAGE
#   MODEL_ID MODEL_PROVIDER MODEL_BASE_URL   (MODEL_PASS_ENV is an array)
#   CFG_PROMPT_FILE
#   PROFILES_ROOT CLEAN_ROOT MEMORY_ROOT MODE
#   CFG_PROFILE_NAME CFG_MEMORY_STORE CFG_KEEP
#   TEMPLATE_SOURCE                    (TEMPLATE_INCLUDE is an array)
#   AUTH_MODE WS_SOURCE DIR_NAME WS_TRUST WS_WORKDIR
#   NET_MODE NET_LOG NET_MITM           (NET_ALLOW is an array)
#   CONFIRM_RW WS_MOUNT_MODE            (RW_ALLOW, DEVICES are arrays)
#   SANDBOX_SSH SANDBOX_USB SANDBOX_HOST_CA
#
# Requires: $LIBDIR set to this file's directory (for jsoncfg.py), python3.

# The config path and whether it was requested explicitly (-c/--config). The
# launcher's pre-parse in main() sets these before load_config runs; defaults here
# keep the library usable when sourced directly (tests).
JSON_CONFIG="${JSON_CONFIG:-./agentdev-config.json}"
JSON_CONFIG_EXPLICIT="${JSON_CONFIG_EXPLICIT:-no}"

# expand_tilde PATH - replace a leading ~ with $HOME. Leaves other paths intact.
expand_tilde() {
  local p="$1"
  case "$p" in
    "~") printf '%s\n' "$HOME" ;;
    "~/"*) printf '%s\n' "$HOME/${p#\~/}" ;;
    *) printf '%s\n' "$p" ;;
  esac
}

# anchor_path PATH - expand ~, make a relative path absolute under CONFIG_DIR, and
# normalize it ("." and ".." segments); the path need not exist. Empty stays empty.
anchor_path() {
  local p; p="$(expand_tilde "$1")"
  [[ -n "$p" ]] || { printf '\n'; return 0; }
  [[ "$p" == /* ]] || p="$CONFIG_DIR/$p"
  realpath -m "$p"
}

_json() { python3 "$LIBDIR/jsoncfg.py" "$@"; }

# cfg_scalar KEY DEFAULT - the key's value from the config file, else DEFAULT.
cfg_scalar() {
  local key="$1" def="$2" val
  if [[ "$CONFIG_PRESENT" == yes ]] && val=$(_json get "$JSON_CONFIG" "$key" 2>/dev/null); then
    printf '%s\n' "$val"; return 0
  fi
  printf '%s\n' "$def"
}

# cfg_path KEY DEFAULT - cfg_scalar, anchored with anchor_path.
cfg_path() { anchor_path "$(cfg_scalar "$1" "$2")"; }

# _read_list KEY ARRAYNAME [path] - fill the named array from the config list (skips
# blank lines). With a third argument "path", each item is anchored with anchor_path.
_read_list() {
  local key="$1" __arr="$2" as_path="${3:-}" line
  eval "$__arr=()"
  [[ "$CONFIG_PRESENT" == yes ]] || return 0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    [[ "$as_path" == path ]] && line="$(anchor_path "$line")"
    eval "$__arr+=(\"\$line\")"
  done < <(_json list "$JSON_CONFIG" "$key" 2>/dev/null || true)
}

load_config() {
  CONFIG_PRESENT=no
  if [[ -f "$JSON_CONFIG" ]]; then
    CONFIG_PRESENT=yes
  elif [[ "$JSON_CONFIG_EXPLICIT" == yes ]]; then
    echo "Error: config file not found: $JSON_CONFIG" >&2
    exit 1
  fi
  if [[ "$CONFIG_PRESENT" == yes ]]; then
    JSON_CONFIG="$(realpath "$JSON_CONFIG")"
    CONFIG_DIR="$(dirname "$JSON_CONFIG")"
    _json check "$JSON_CONFIG" || { echo "Error: invalid config file: $JSON_CONFIG" >&2; exit 1; }
    _json validate "$JSON_CONFIG" || { echo "Error: config file failed validation: $JSON_CONFIG" >&2; exit 1; }
  else
    CONFIG_DIR="$PWD"
  fi

  # --- agent ----------------------------------------------------------------
  AGENT_NAME=$(cfg_scalar "agent.name" "claude")
  IMAGE=$(cfg_scalar "agent.image" "ghcr.io/gherlein/agentdev:latest")

  # --- model ----------------------------------------------------------------
  MODEL_ID=$(cfg_scalar "model.id" "")
  MODEL_PROVIDER=$(cfg_scalar "model.provider" "anthropic")
  MODEL_BASE_URL=$(cfg_scalar "model.base_url" "")
  _read_list "model.pass_env" MODEL_PASS_ENV

  # --- prompt ---------------------------------------------------------------
  CFG_PROMPT_FILE=$(cfg_path "prompt.file" "")

  # --- profile --------------------------------------------------------------
  MODE=$(cfg_scalar "profile.mode" "clean")
  CFG_PROFILE_NAME=$(cfg_scalar "profile.name" "")
  CFG_MEMORY_STORE=$(cfg_scalar "profile.memory_store" "default")
  CFG_KEEP=$(cfg_scalar "profile.keep" "false")
  PROFILES_ROOT=$(cfg_path "profile.profiles_root" "$HOME/.agentdev/profiles")
  CLEAN_ROOT=$(cfg_path "profile.clean_root" "$HOME/.cache/agentdev/clean")
  MEMORY_ROOT=$(cfg_path "profile.memory_root" "$HOME/.agentdev/memory")

  # --- template -------------------------------------------------------------
  TEMPLATE_SOURCE=$(cfg_path "template.source" "$SELFDIR/templates/default")
  _read_list "template.include" TEMPLATE_INCLUDE
  if [[ ${#TEMPLATE_INCLUDE[@]} -eq 0 ]]; then
    TEMPLATE_INCLUDE=("CLAUDE.md" "settings.json" "hooks" "skills" ".mcp.json")
  fi

  # --- auth -----------------------------------------------------------------
  AUTH_MODE=$(cfg_scalar "auth.mode" "auto")

  # --- workspace ------------------------------------------------------------
  # The host folder mounted at /<basename>; "." is the config file's directory.
  WS_SOURCE=$(cfg_path "workspace.source" ".")
  WS_SOURCE="${WS_SOURCE%/}"
  [[ -n "$WS_SOURCE" ]] || WS_SOURCE="/"
  DIR_NAME="$(basename "$WS_SOURCE")"
  WS_TRUST=$(cfg_scalar "workspace.trust" "skip-permissions")
  # The entry folder: where the container's shell starts (the bash cwd). Empty or
  # "." means the workspace root. Relative paths resolve under the workspace mount;
  # an absolute path is used as-is.
  WS_WORKDIR=$(cfg_scalar "workspace.workdir" "")

  # --- network --------------------------------------------------------------
  NET_MODE=$(cfg_scalar "network.mode" "off")
  NET_LOG=$(cfg_scalar "network.log" "false")
  NET_MITM=$(cfg_scalar "network.mitm" "false")
  _read_list "network.allow" NET_ALLOW

  # --- mounts ---------------------------------------------------------------
  WS_MOUNT_MODE=$(cfg_scalar "mounts.workspace" "rw")
  CONFIRM_RW=$(cfg_scalar "mounts.confirm_rw" "false")
  _read_list "mounts.rw_allow" RW_ALLOW path
  _read_list "mounts.devices" DEVICES

  # --- sandbox --------------------------------------------------------------
  SANDBOX_SSH=$(cfg_scalar "sandbox.ssh" "true")
  SANDBOX_USB=$(cfg_scalar "sandbox.usb" "true")
  SANDBOX_HOST_CA=$(cfg_scalar "sandbox.host_ca" "true")
}
