#!/bin/bash
# profile.sh - resolve, lock, and manage profiles. A profile is a plain folder;
# agentdev never versions it (run git yourself if you want history).
# Requires: flock; globals PROFILES_ROOT, CLEAN_ROOT, SELFDIR.

# new_run_id - a sortable, unique run identifier.
new_run_id() {
  printf '%s-%s\n' "$(date -u +%Y%m%dT%H%M%S)" "$(head -c4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
}

# lock_profile PATH - take an exclusive, non-blocking lock so a named profile
# cannot be launched twice at once. The lock releases when the launcher exits
# (the fd is held by the shell). Sets PROFILE_LOCK_FD. This guards two launchers
# racing; a launcher whose container was orphaned is caught by assert_profile_free.
lock_profile() {
  local path="$1"
  mkdir -p "$path"
  exec {PROFILE_LOCK_FD}>"$path/.agentdev.lock-file"
  if ! flock -n "$PROFILE_LOCK_FD"; then
    echo "Error: profile is already in use by another agentdev run: $path" >&2
    exit 1
  fi
}

# profile_container_name PATH - a deterministic, charset-safe podman --name for a
# profile folder. Because the name is fixed per folder, the runtime itself refuses
# a second `podman run` on the same profile (and `--rm` frees the name when the
# container stops), enforcing single-instance even if this launcher is killed.
profile_container_name() {
  printf 'agentdev-%s\n' "$(printf '%s' "$1" | sha256sum | cut -c1-12)"
}

# assert_profile_free PATH - refuse to launch if a live container is already
# mounting this profile folder. The flock catches two launchers; this catches a
# launcher whose container was orphaned (launcher killed, container still writing
# the folder). The folder, not the process, is the resource being protected.
assert_profile_free() {
  local path="$1" cid
  cid=$(podman ps --filter "label=agentdev.profile=$path" --format '{{.ID}}' 2>/dev/null | head -n1)
  if [[ -n "$cid" ]]; then
    echo "Error: profile folder is in use by a running container: $path" >&2
    echo "       container: $cid" >&2
    echo "       If that run is orphaned (no launcher attached), reap it with:" >&2
    echo "         agentdev profiles gc" >&2
    exit 1
  fi
}

# cmd_profiles - the `agentdev profiles …` subcommand surface.
cmd_profiles() {
  local sub="${1:-ls}"; shift || true
  case "$sub" in
    ls)
      [[ -d "$PROFILES_ROOT" ]] || { echo "(no profiles)"; return 0; }
      find "$PROFILES_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort ;;
    show)
      local p="$PROFILES_ROOT/${1:?usage: profiles show <name>}"
      [[ -f "$p/agentdev.meta.json" ]] && cat "$p/agentdev.meta.json" || echo "no such profile: $1" >&2 ;;
    new)
      # Create and seed a named profile without launching.
      MODE="profile"; RUN_ID=$(new_run_id)
      PROFILE="$PROFILES_ROOT/${1:?usage: profiles new <name>}"
      [[ -d "$PROFILE" ]] && { echo "profile already exists: $1" >&2; return 1; }
      compute_enc "$DIR_NAME"
      seed_profile; write_meta; write_lock
      echo "Created profile: $PROFILE" ;;
    rm)
      rm -rf "${PROFILES_ROOT:?}/${1:?usage: profiles rm <name>}"; echo "removed profile: $1" ;;
    fork)
      local src="$PROFILES_ROOT/${1:?usage: profiles fork <src> <dst>}"
      local dst="$PROFILES_ROOT/${2:?usage: profiles fork <src> <dst>}"
      [[ -d "$src" ]] || { echo "no such profile: $1" >&2; return 1; }
      [[ -d "$dst" ]] && { echo "destination exists: $2" >&2; return 1; }
      cp -a "$src" "$dst"; echo "forked $1 -> $2" ;;
    gc)
      # Sweep crashed clean-room leftovers.
      if [[ -d "$CLEAN_ROOT" ]]; then
        local n; n=$(find "$CLEAN_ROOT" -mindepth 1 -maxdepth 1 -type d | wc -l)
        rm -rf "${CLEAN_ROOT:?}"/*; echo "gc: swept $n clean-room leftover(s)"
      else
        echo "gc: nothing to sweep"
      fi
      # Reap orphaned profile containers. A container is orphaned when no launcher
      # holds its profile's lock: we can take the lock iff the launcher is gone, so
      # flock itself distinguishes orphaned (reap) from active (leave running). The
      # rm runs while we hold the lock, so a fresh launch can't race in behind it.
      local cid ppath
      while read -r cid ppath; do
        [[ -n "$cid" && -n "$ppath" ]] || continue
        if flock -n "$ppath/.agentdev.lock-file" -c "podman rm -f '$cid' >/dev/null 2>&1"; then
          echo "gc: reaped orphaned profile container $cid ($ppath)"
        else
          echo "gc: profile container $cid ($ppath) is active; left running" >&2
        fi
      done < <(podman ps -a --filter 'label=agentdev.profile' \
                 --format '{{.ID}} {{index .Labels "agentdev.profile"}}' 2>/dev/null)
      # Reap egress proxy sidecars and networks left by crashed allowlist runs.
      gc_networks ;;
    *) echo "Usage: agentdev profiles ls|show|new|rm|fork|gc [args]" >&2; return 1 ;;
  esac
}
