#!/bin/bash
# mounts.sh - agentdev's own external-mount collection (no localdev dependency).
#
# Mounts come only from the config file: mounts.read_only / mounts.read_write maps
# and the mounts.devices list. A source that does not exist, is not a directory, or
# is unreadable aborts the launch (fail-closed); so does a missing device.
#
# Populates:
#   VOLUME_MOUNTS   array of "-v host:container:mode"
#   DEVICE_MOUNTS   array of "--device path"
#   MOUNTS_CONTENT  the in-container ~/mounts map (printf %b string)
#
# collect_host_ca_mount() is a separate entry point for host TLS anchors; it sets
# CA_CERT_MOUNT and CA_CERT_ENV and must run after collect_mounts().
#
# Every mount claims exactly one container-side target; a second claim is fatal.
# Requires $LIBDIR (for jsoncfg.py), python3, and the config globals.

# Container paths agentdev manages itself; a user mount may target none of these.
RESERVED_TARGETS=(
  /home/developer/.claude
  /home/developer/.claude.json
  /home/developer/.ssh
  /home/developer/.npm
  /home/developer/mounts
  /home/developer/.agentdev-prompt
  /ssh-agent
  /usr/local/share/ca-certificates
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

# resolve_dir PATH DESC - print the normalized absolute path of an existing,
# readable directory, or abort naming DESC.
resolve_dir() {
  local path="$1" desc="$2" resolved
  if ! resolved=$(realpath -e "$path" 2>/dev/null) || [[ ! -d "$resolved" ]]; then
    echo "Error: $desc: not an existing directory: $path" >&2
    exit 1
  fi
  if [[ ! -r "$resolved" ]]; then
    echo "Error: $desc: not readable: $resolved" >&2
    exit 1
  fi
  printf '%s\n' "$resolved"
}

add_device_mount() {
  local path="$1"
  if [[ ! -c "$path" && ! -b "$path" ]]; then
    echo "Error: mounts.devices: not a character or block device: $path" >&2
    exit 1
  fi
  DEVICE_MOUNTS+=("--device" "$path")
  echo "Device passthrough:    $path" >&2
}

# _mount SRC TARGET MODE DESC - low-level add with the collision check.
_mount() {
  local src="$1" target="$2" mode="$3" desc="$4"
  register_target "$target" "$desc"
  VOLUME_MOUNTS+=("-v" "${src}:${target}:${mode}")
  local label="read-only"; [[ "$mode" == "rw" ]] && label="read-write"
  printf 'Mounting (%s): %s -> %s\n' "$label" "$src" "$target" >&2
  MOUNTS_CONTENT+="$src -> ${target} (${label})\n"
}

# confirm_rw_mount HOST TARGET - gate a read-write mount. Prints nothing and
# returns 0 (allow) unless CONFIRM_RW=true. When confirming: a HOST matching an
# entry in RW_ALLOW (resolved) is auto-approved; otherwise prompt on /dev/tty; a
# run with no controlling terminal denies (fail-closed) so unattended/eval runs
# cannot silently gain write access. Returns 1 to deny.
confirm_rw_mount() {
  [[ "${CONFIRM_RW:-false}" == true ]] || return 0
  [[ "${DRY_RUN:-no}" == yes ]] && return 0   # --dry-run must not prompt
  local host="$1" target="$2" entry resolved_host resolved_entry ans
  resolved_host=$(realpath "$host" 2>/dev/null || printf '%s' "$host")
  for entry in "${RW_ALLOW[@]:-}"; do
    [[ -z "$entry" ]] && continue
    resolved_entry=$(realpath "$(expand_tilde "$entry")" 2>/dev/null || printf '%s' "$entry")
    if [[ "$resolved_entry" == "$resolved_host" ]]; then
      echo "rw mount pre-approved (mounts.rw_allow): $resolved_host -> $target" >&2
      return 0
    fi
  done
  # Probe by actually opening /dev/tty: the device node can exist while open()
  # fails with ENXIO when there is no controlling terminal (CI, nohup, a harness).
  if { exec 3<>/dev/tty; } 2>/dev/null; then
    printf 'Allow READ-WRITE mount  %s -> %s ? [y/N] ' "$resolved_host" "$target" >&3
    read -r ans <&3 || ans=""
    exec 3>&-
    case "$ans" in
      [yY]|[yY][eE][sS]) return 0 ;;
      *) echo "rw mount denied: $resolved_host -> $target" >&2; return 1 ;;
    esac
  fi
  echo "Refusing read-write mount (no terminal to confirm; fail-closed): $resolved_host -> $target" >&2
  echo "       pre-approve it in mounts.rw_allow, or mount it read-only." >&2
  return 1
}

# _resolve_dest WORKSPACE SRC DEST -> absolute container path.
_resolve_dest() {
  local workspace="$1" src="$2" dest="$3"
  case "$dest" in
    "&") printf '/%s\n' "$(basename "$src")" ;;
    /*)  printf '%s\n' "$dest" ;;
    *)   printf '%s/%s\n' "$workspace" "$dest" ;;
  esac
}

# _mounts_from_config WORKSPACE - apply the config's mounts.read_only /
# mounts.read_write maps. Each entry is "src": "dest", where src is anchored at the
# config file's directory and dest is an absolute container path, a path relative
# to the workspace, or "&" to mirror src's basename at the container root.
_mounts_from_config() {
  local workspace="$1"
  [[ "$CONFIG_PRESENT" == yes ]] || return 0
  local key mode src dest rsrc target entries
  for key in read_only read_write; do
    mode=ro; [[ "$key" == read_write ]] && mode=rw
    entries=$(python3 "$LIBDIR/jsoncfg.py" table "$JSON_CONFIG" "mounts.$key" 2>/dev/null || true)
    while IFS=$'\t' read -r src dest; do
      [[ -n "$src" ]] || continue
      rsrc=$(resolve_dir "$(anchor_path "$src")" "mounts.$key \"$src\"")
      target=$(_resolve_dest "$workspace" "$rsrc" "$dest")
      if [[ "$mode" == rw ]] && ! confirm_rw_mount "$rsrc" "$target"; then
        continue
      fi
      _mount "$rsrc" "$target" "$mode" "mounts.$key $src"
    done <<< "$entries"
  done
}

collect_mounts() {
  local toolname="$1" dirname="$2"
  VOLUME_MOUNTS=(); DEVICE_MOUNTS=()
  MOUNTS_CONTENT="# ${toolname} mount map\n# HOST PATH -> CONTAINER PATH (mode)\n"
  USED_TARGETS=()

  register_target "/${dirname}" "workspace"
  local r
  for r in "${RESERVED_TARGETS[@]}"; do USED_TARGETS["$r"]="reserved (managed mount)"; done

  _mounts_from_config "/${dirname}"
  local device
  for device in "${DEVICES[@]:-}"; do
    [[ -n "$device" ]] && add_device_mount "$device"
  done
  return 0
}

# collect_host_ca_mount - pass the host's extra TLS trust anchors read-only so
# cert verification inside the container matches the host.
collect_host_ca_mount() {
  CA_CERT_MOUNT=(); CA_CERT_ENV=()
  local anchors=""
  if [[ -d /usr/local/share/ca-certificates ]]; then anchors=/usr/local/share/ca-certificates
  elif [[ -d /etc/pki/ca-trust/source/anchors ]]; then anchors=/etc/pki/ca-trust/source/anchors
  fi
  [[ -z "$anchors" ]] && return 0
  # Only bother if the host actually has extra anchors installed.
  if [[ -n "$(find "$anchors" -maxdepth 1 -type f 2>/dev/null | head -1)" ]]; then
    CA_CERT_MOUNT=("-v" "${anchors}:/usr/local/share/ca-certificates:ro")
    CA_CERT_ENV=("-e" "REFRESH_CA_CERTS=1" "-e" "NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt")
    echo "Mounting (read-only): ${anchors} -> /usr/local/share/ca-certificates" >&2
    MOUNTS_CONTENT+="${anchors} -> /usr/local/share/ca-certificates (read-only)\n"
  fi
}
