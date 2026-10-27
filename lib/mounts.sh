#!/bin/bash
# mounts.sh - build the podman mount plan from the config. Everything the container
# sees that is not in the base image comes from here: the workspace, files injected
# into it (workspace.files), the agent's home (mounts.agent_folder) with optional
# history/memory redirects, extra read-only/read-write folders, and tty devices.
# Container-side target collisions are fatal.
#
# Populates: WORKSPACE_MOUNT, VOLUME_MOUNTS, HOME_MOUNTS, DEVICE_MOUNTS (arrays) and
# MOUNTS_CONTENT (the in-container ~/mounts map). collect_ssh_mount sets SSH_MOUNT /
# SSH_AGENT. Requires $LIBDIR, python3, the config globals, agents.sh, and (for the
# home layout + redirects) OS_AGENT and ENC from the launcher. mkdir side effects are
# skipped when DRY_RUN=yes.

RESERVED_TARGETS=(
  /home/developer/.ssh
  /home/developer/mounts
  /home/developer/.agentdev-prompt
  /ssh-agent
)

declare -A USED_TARGETS

register_target() {
  local target="$1" desc="$2"
  if [[ -n "${USED_TARGETS[$target]:-}" ]]; then
    echo "Error: mount target collision on '$target'" >&2
    echo "       requested by:    $desc" >&2
    echo "       already used by: ${USED_TARGETS[$target]}" >&2
    exit 1
  fi
  USED_TARGETS["$target"]="$desc"
}

# resolve_dir PATH DESC -> normalized path of an existing, readable directory, else abort.
resolve_dir() {
  local path="$1" desc="$2" r
  if ! r=$(realpath -e "$path" 2>/dev/null) || [[ ! -d "$r" ]]; then
    echo "Error: $desc: not an existing directory: $path" >&2; exit 1
  fi
  [[ -r "$r" ]] || { echo "Error: $desc: not readable: $r" >&2; exit 1; }
  printf '%s\n' "$r"
}

# resolve_file PATH DESC -> normalized path of an existing, readable file, else abort.
resolve_file() {
  local path="$1" desc="$2" r
  if ! r=$(realpath -e "$path" 2>/dev/null) || [[ ! -f "$r" ]]; then
    echo "Error: $desc: not an existing file: $path" >&2; exit 1
  fi
  [[ -r "$r" ]] || { echo "Error: $desc: not readable: $r" >&2; exit 1; }
  printf '%s\n' "$r"
}

_add() {   # SRC TARGET MODE DESC -> append a -v with the collision check
  local src="$1" target="$2" mode="$3" desc="$4"
  register_target "$target" "$desc"
  VOLUME_MOUNTS+=("-v" "${src}:${target}:${mode}")
  local label="read-only"; [[ "$mode" == rw ]] && label="read-write"
  printf 'Mounting (%s): %s -> %s\n' "$label" "$src" "$target" >&2
  MOUNTS_CONTENT+="$src -> ${target} (${label})\n"
}

# collect_mounts DIR_NAME - DIR_NAME is the resolved workspace mount name.
collect_mounts() {
  local dir="$1"
  WORKSPACE_MOUNT=(); VOLUME_MOUNTS=(); DEVICE_MOUNTS=(); HOME_MOUNTS=()
  MOUNTS_CONTENT="# agentdev mount map\n# HOST PATH -> CONTAINER PATH (mode)\n"
  USED_TARGETS=()

  register_target "/$dir" "workspace"
  local r; for r in "${RESERVED_TARGETS[@]}"; do USED_TARGETS["$r"]="reserved"; done

  WORKSPACE_MOUNT=("-v" "$WS_SOURCE:/$dir:$WS_MODE")
  MOUNTS_CONTENT+="$WS_SOURCE -> /$dir ($WS_MODE)\n"

  _mount_files "$dir"
  _mount_home
  _mount_folders read_only ro
  _mount_folders read_write rw

  local d
  for d in "${TTY_DEVICES[@]:-}"; do
    [[ -n "$d" ]] || continue
    [[ -c "$d" || -b "$d" ]] || { echo "Error: mounts.tty_devices: not a device: $d" >&2; exit 1; }
    DEVICE_MOUNTS+=("--device" "$d")
    echo "Device passthrough:    $d" >&2
  done
  return 0
}

# _mount_files - workspace.files: host files bind-mounted read-only into the working dir.
_mount_files() {
  local dir="$1" src name rsrc
  [[ "$CONFIG_PRESENT" == yes ]] || return 0
  while IFS=$'\t' read -r src name; do
    [[ -n "$src" && -n "$name" ]] || continue
    rsrc=$(resolve_file "$(anchor_path "$src")" "workspace.files \"$src\"")
    _add "$rsrc" "/$dir/$name" ro "workspace.files $src"
  done < <(_json rows "$JSON_CONFIG" "workspace.files" source name 2>/dev/null || true)
}

# _mount_folders KEY MODE - mounts.read_only / mounts.read_write, { src, dest } pairs.
_mount_folders() {
  local key="$1" mode="$2" src dest rsrc
  [[ "$CONFIG_PRESENT" == yes ]] || return 0
  while IFS=$'\t' read -r src dest; do
    [[ -n "$src" && -n "$dest" ]] || continue
    [[ "$dest" == /* ]] || { echo "Error: mounts.$key: dest must be an absolute container path: $dest" >&2; exit 1; }
    rsrc=$(resolve_dir "$(anchor_path "$src")" "mounts.$key \"$src\"")
    _add "$rsrc" "$dest" "$mode" "mounts.$key $src"
  done < <(_json rows "$JSON_CONFIG" "mounts.$key" src dest 2>/dev/null || true)
}

# _mount_home - mount the agent's home dir(s) from agent_folder (pre-creating an
# empty, host-owned home when the folder is new), then overlay the optional history
# and memory redirects at the agent-specific path agentdev knows.
_mount_home() {
  local item kind host cont
  if [[ -n "$MNT_AGENT_FOLDER" ]]; then
    [[ "$DRY_RUN" == yes ]] || mkdir -p "$MNT_AGENT_FOLDER"
    while IFS=$'\t' read -r item kind; do
      [[ -n "$item" ]] || continue
      host="$MNT_AGENT_FOLDER/$item"; cont="$AGENT_HOME/$item"
      if [[ "$DRY_RUN" != yes ]]; then
        if [[ "$kind" == dir ]]; then mkdir -p "$host"; else [[ -e "$host" ]] || : > "$host"; fi
      fi
      register_target "$cont" "agent home ($item)"
      HOME_MOUNTS+=("-v" "$host:$cont:rw")
      MOUNTS_CONTENT+="$host -> $cont (read-write)\n"
    done < <(agent_home_items "$OS_AGENT")
  fi

  local hist mem
  if [[ -n "$MNT_HISTORY" ]]; then
    hist=$(agent_history_dest "$OS_AGENT" "$ENC")
    [[ -n "$hist" ]] || { echo "Error: agent '$OS_AGENT' has no separable history folder; remove mounts.history." >&2; exit 1; }
    [[ "$DRY_RUN" == yes ]] || mkdir -p "$MNT_HISTORY"
    register_target "$hist" "mounts.history"
    HOME_MOUNTS+=("-v" "$MNT_HISTORY:$hist:rw")
    MOUNTS_CONTENT+="$MNT_HISTORY -> $hist (read-write)\n"
  fi
  if [[ -n "$MNT_MEMORY" ]]; then
    mem=$(agent_memory_dest "$OS_AGENT" "$ENC")
    [[ -n "$mem" ]] || { echo "Error: agent '$OS_AGENT' has no separable memory folder; remove mounts.memory." >&2; exit 1; }
    [[ "$DRY_RUN" == yes ]] || mkdir -p "$MNT_MEMORY"
    register_target "$mem" "mounts.memory"
    HOME_MOUNTS+=("-v" "$MNT_MEMORY:$mem:rw")
    MOUNTS_CONTENT+="$MNT_MEMORY -> $mem (read-write)\n"
  fi
}

# collect_ssh_mount - workspace.ssh: mount host ~/.ssh read-only + forward the agent socket.
collect_ssh_mount() {
  SSH_MOUNT=(); SSH_AGENT=()
  [[ "$WS_SSH" == true ]] || return 0
  [[ -d "$HOME/.ssh" ]] && SSH_MOUNT=("-v" "$HOME/.ssh:/home/developer/.ssh:ro")
  if [[ -n "${SSH_AUTH_SOCK:-}" && -S "${SSH_AUTH_SOCK:-}" ]]; then
    SSH_AGENT=("-v" "$SSH_AUTH_SOCK:/ssh-agent" "-e" "SSH_AUTH_SOCK=/ssh-agent")
  fi
}
