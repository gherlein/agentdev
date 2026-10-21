#!/bin/bash
# mounts.sh - agentdev's own external-mount collection (no localdev dependency).
#
# Single entry point collect_mounts() unions three sources into podman args:
#   1. CLI arguments:   -rw <path>, -ro <path>, bare <path> (ro), /dev/* (device)
#   2. AGENTDEV_MOUNTS: whitespace-separated host dirs, each mounted read-only
#   3. .agentdev-mounts.toml in the launch dir: [read-only] / [read-write] tables
#
# Populates:
#   VOLUME_MOUNTS   array of "-v host:container:mode"
#   DEVICE_MOUNTS   array of "--device path"
#   MOUNTS_CONTENT  the in-container ~/mounts map (printf %b string)
#   MOUNT_ERRORS    count of non-fatal skipped mounts
#
# collect_host_ca_mount() is a separate entry point for host TLS anchors; it sets
# CA_CERT_MOUNT and CA_CERT_ENV and must run after collect_mounts().
#
# Every mount claims exactly one container-side target; a second claim is fatal.
# Requires $LIBDIR (for toml.py) and python3.

MOUNT_FILE_NAME=".agentdev-mounts.toml"

# Container paths agentdev manages itself; a user mount may target none of these.
RESERVED_TARGETS=(
  /home/developer/.claude
  /home/developer/.claude.json
  /home/developer/.ssh
  /home/developer/.npm
  /home/developer/mounts
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

# resolve_path PATH -> normalized, existing, absolute directory (on stdout).
resolve_path() {
  local path="$1"
  if [[ "$path" != /* ]]; then
    path="$(cd "$(dirname "$path")" 2>/dev/null && pwd)/$(basename "$path")" || {
      echo "Warning: cannot resolve path '$1'" >&2; return 1; }
  fi
  path=$(realpath "$path" 2>/dev/null) || {
    echo "Warning: cannot normalize path '$1'" >&2; return 1; }
  if [[ ! -d "$path" ]]; then
    echo "Warning: skipping non-existent directory '$path'" >&2; return 1
  fi
  printf '%s\n' "$path"
}

add_device_mount() {
  local path="$1"
  if [[ ! -e "$path" ]]; then
    echo "Warning: skipping non-existent device '$path'" >&2; return 1
  fi
  if [[ ! -c "$path" && ! -b "$path" ]]; then
    echo "Warning: '$path' is not a device file" >&2; return 1
  fi
  DEVICE_MOUNTS+=("--device" "$path")
  echo "Device passthrough:    $path" >&2
}

# _mount SRC TARGET MODE DESC - low-level add with collision + readability checks.
_mount() {
  local src="$1" target="$2" mode="$3" desc="$4"
  if [[ ! -r "$src" ]]; then
    echo "Warning: skipping unreadable '$src' (permission denied)" >&2
    ((MOUNT_ERRORS++)); return 1
  fi
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
      echo "rw mount pre-approved (--rw-allow): $resolved_host -> $target" >&2
      return 0
    fi
  done
  if [[ -r /dev/tty && -w /dev/tty ]]; then
    printf 'Allow READ-WRITE mount  %s -> %s ? [y/N] ' "$resolved_host" "$target" > /dev/tty
    read -r ans < /dev/tty || ans=""
    case "$ans" in
      [yY]|[yY][eE][sS]) return 0 ;;
      *) echo "rw mount denied: $resolved_host -> $target" >&2; return 1 ;;
    esac
  fi
  echo "Refusing read-write mount (no terminal to confirm; fail-closed): $resolved_host -> $target" >&2
  echo "       pre-approve with '--rw-allow $resolved_host', or mount it read-only." >&2
  return 1
}

add_ro_mount() { local p; p=$(resolve_path "$1") || return 1; _mount "$p" "/external/$(basename "$p")" ro "CLI/env ro mount of $p"; }
add_rw_mount() {
  local p; p=$(resolve_path "$1") || return 1
  confirm_rw_mount "$p" "/external/$(basename "$p")" || return 0
  _mount "$p" "/external/$(basename "$p")" rw "CLI/env rw mount of $p"
}

# _process_cli_mounts ARGS... - returns only the leftover (non-mount) args via
# the global CLI_LEFTOVER array, so the launcher can keep flags it owns.
_process_cli_mounts() {
  CLI_LEFTOVER=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -rw) shift; [[ -n "$1" ]] && add_rw_mount "$1" ;;
      -ro) shift; [[ -n "$1" ]] && add_ro_mount "$1" ;;
      /dev/*) add_device_mount "$1" ;;
      -* ) CLI_LEFTOVER+=("$1") ;;      # a flag agentdev owns; leave it
      * )
        if [[ -d "$1" ]]; then add_ro_mount "$1"; else CLI_LEFTOVER+=("$1"); fi
        ;;
    esac
    shift
  done
}

_process_env_mounts() {
  [[ -z "${AGENTDEV_MOUNTS:-}" ]] && return 0
  local entry
  for entry in $AGENTDEV_MOUNTS; do
    [[ -n "$entry" ]] && add_ro_mount "$entry"
  done
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

_process_file_mounts() {
  local workspace="$1"
  [[ -f "$MOUNT_FILE_NAME" ]] || return 0
  if ! python3 "$LIBDIR/toml.py" check "$MOUNT_FILE_NAME"; then
    echo "Error: invalid $MOUNT_FILE_NAME" >&2; exit 1
  fi
  local table mode src dest rsrc target line
  for table in read-only read-write; do
    mode=ro; [[ "$table" == read-write ]] && mode=rw
    while IFS=$'\t' read -r src dest; do
      [[ -z "$src" ]] && continue
      rsrc=$(resolve_path "$(expand_tilde "$src")") || { ((MOUNT_ERRORS++)); continue; }
      target=$(_resolve_dest "$workspace" "$rsrc" "$dest")
      [[ "$mode" == rw ]] && { confirm_rw_mount "$rsrc" "$target" || continue; }
      _mount "$rsrc" "$target" "$mode" "$MOUNT_FILE_NAME [$table] $src"
    done < <(python3 "$LIBDIR/toml.py" table "$MOUNT_FILE_NAME" "$table" 2>/dev/null)
  done
}

collect_mounts() {
  local toolname="$1" dirname="$2"; shift 2
  VOLUME_MOUNTS=(); DEVICE_MOUNTS=(); MOUNT_ERRORS=0
  MOUNTS_CONTENT="# ${toolname} mount map\n# HOST PATH -> CONTAINER PATH (mode)\n"
  USED_TARGETS=()

  register_target "/${dirname}" "workspace"
  local r
  for r in "${RESERVED_TARGETS[@]}"; do USED_TARGETS["$r"]="reserved (managed mount)"; done

  _process_cli_mounts "$@"
  _process_env_mounts
  _process_file_mounts "/${dirname}"
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

handle_init_flag() {
  local target="$MOUNT_FILE_NAME"
  if [[ -e "$target" ]]; then
    echo "Error: $target already exists; not overwriting." >&2; exit 1
  fi
  cat > "$target" <<'EOF'
# .agentdev-mounts.toml - extra mounts applied on every agentdev launch here.
#
# source = destination, where:
#   source       host dir: absolute, or relative to this directory
#   destination  absolute container path, a path relative to the workspace,
#                or "&" to mirror a relative source's basename at the container root
#
# Relative paths and "&" are portable and safe to commit; absolute host paths
# should stay gitignored. Any error in this file aborts the launch.

[read-only]
# "~/ref/standards" = "/external/standards"
# "../sibling-repo" = "&"

[read-write]
# "~/out/shared"    = "/external/shared"
EOF
  echo "Wrote $target" >&2
}
