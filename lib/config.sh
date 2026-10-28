#!/bin/bash
# config.sh - the single JSON config file for agentdev. One file defines a launch;
# there is no user layer and no environment-variable input. The file is validated
# fail-closed against the schema in jsoncfg.py before any key is read. Relative paths
# resolve against the directory that holds the file.
#
# Globals set:
#   CONFIG_PRESENT CONFIG_DIR JSON_CONFIG
#   IMAGE
#   WS_SOURCE WS_MOUNT WS_MODE WS_SSH WS_USB
#   NET_MODE NET_LOG NET_MITM            (NET_ALLOW is an array)
#   MNT_AGENT_FOLDER MNT_HISTORY MNT_MEMORY   (TTY_DEVICES is an array)
#   SKILLS_STORE SKILLS_PROFILE               (SKILLS_INCLUDE is an array)
#   HAVE_ONESHOT OS_AGENT OS_MODEL OS_PROMPT
# The mount pair-lists (workspace.files, mounts.read_only/read_write) are read
# directly from the file by mounts.sh via `jsoncfg.py rows`.
#
# Requires: $LIBDIR set (for jsoncfg.py), python3.

JSON_CONFIG="${JSON_CONFIG:-./agentdev-config.json}"
JSON_CONFIG_EXPLICIT="${JSON_CONFIG_EXPLICIT:-no}"

# expand_tilde PATH - replace a leading ~ with $HOME; leave other paths intact.
expand_tilde() {
  local p="$1"
  case "$p" in
    "~") printf '%s\n' "$HOME" ;;
    "~/"*) printf '%s\n' "$HOME/${p#\~/}" ;;
    *) printf '%s\n' "$p" ;;
  esac
}

# anchor_path PATH - expand ~, make relative paths absolute under CONFIG_DIR, and
# normalize; the path need not exist. Empty stays empty.
anchor_path() {
  local p; p="$(expand_tilde "$1")"
  [[ -n "$p" ]] || { printf '\n'; return 0; }
  [[ "$p" == /* ]] || p="$CONFIG_DIR/$p"
  realpath -m "$p"
}

_json() { python3 "$LIBDIR/jsoncfg.py" "$@"; }

cfg_scalar() {
  local key="$1" def="$2" val
  if [[ "$CONFIG_PRESENT" == yes ]] && val=$(_json get "$JSON_CONFIG" "$key" 2>/dev/null); then
    printf '%s\n' "$val"; return 0
  fi
  printf '%s\n' "$def"
}
cfg_path() { anchor_path "$(cfg_scalar "$1" "$2")"; }

_read_list() {
  local key="$1" __arr="$2" line
  eval "$__arr=()"
  [[ "$CONFIG_PRESENT" == yes ]] || return 0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    eval "$__arr+=(\"\$line\")"
  done < <(_json list "$JSON_CONFIG" "$key" 2>/dev/null || true)
}

load_config() {
  CONFIG_PRESENT=no
  if [[ -f "$JSON_CONFIG" ]]; then
    CONFIG_PRESENT=yes
  elif [[ "$JSON_CONFIG_EXPLICIT" == yes ]]; then
    echo "Error: config file not found: $JSON_CONFIG" >&2; exit 1
  fi
  if [[ "$CONFIG_PRESENT" == yes ]]; then
    JSON_CONFIG="$(realpath "$JSON_CONFIG")"
    CONFIG_DIR="$(dirname "$JSON_CONFIG")"
    _json check "$JSON_CONFIG"    || { echo "Error: invalid config file: $JSON_CONFIG" >&2; exit 1; }
    _json validate "$JSON_CONFIG" || { echo "Error: config file failed validation: $JSON_CONFIG" >&2; exit 1; }
  else
    CONFIG_DIR="$PWD"
  fi

  IMAGE=$(cfg_scalar "image" "ghcr.io/gherlein/agentdev:latest")

  # --- workspace ---
  WS_SOURCE=$(cfg_path "workspace.source" ".")
  WS_SOURCE="${WS_SOURCE%/}"; [[ -n "$WS_SOURCE" ]] || WS_SOURCE="/"
  WS_MOUNT=$(cfg_scalar "workspace.mount" "")       # empty -> basename, resolved in the launcher
  WS_MODE=$(cfg_scalar "workspace.mode" "rw")
  WS_SSH=$(cfg_scalar "workspace.ssh" "true")
  WS_USB=$(cfg_scalar "workspace.usb" "true")

  # --- network ---
  NET_MODE=$(cfg_scalar "network.mode" "off")
  NET_LOG=$(cfg_scalar "network.log" "false")
  NET_MITM=$(cfg_scalar "network.mitm" "false")
  _read_list "network.allow" NET_ALLOW

  # --- mounts ---
  MNT_AGENT_FOLDER=$(cfg_path "mounts.agent_folder" "")
  MNT_HISTORY=$(cfg_path "mounts.history" "")
  MNT_MEMORY=$(cfg_path "mounts.memory" "")
  _read_list "mounts.tty_devices" TTY_DEVICES

  # --- skills (optional; a bundle from the shared store) ---
  # SKILLS_STORE stays empty unless a skills block is present, so a config without
  # one carries no store requirement. profile/include default to empty.
  SKILLS_STORE=""
  SKILLS_PROFILE=$(cfg_scalar "skills.profile" "")
  _read_list "skills.include" SKILLS_INCLUDE
  if [[ "$CONFIG_PRESENT" == yes ]] && _json has "$JSON_CONFIG" "skills"; then
    SKILLS_STORE=$(cfg_path "skills.store" "${XDG_DATA_HOME:-$HOME/.local/share}/skills")
  fi

  # --- one-shot (optional; absence => interactive) ---
  HAVE_ONESHOT=no
  if [[ "$CONFIG_PRESENT" == yes ]] && _json has "$JSON_CONFIG" "one-shot"; then
    HAVE_ONESHOT=yes
  fi
  OS_AGENT=$(cfg_scalar "one-shot.agent" "claude")
  OS_MODEL=$(cfg_scalar "one-shot.model" "")
  OS_PROMPT=$(cfg_path "one-shot.prompt" "")
}
