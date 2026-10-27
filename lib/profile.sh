#!/bin/bash
# profile.sh - resolve and lock a named profile for a launch. A profile is a plain
# folder; agentdev never versions it and offers no management subcommands — manage
# the folders yourself (cp to fork, rm to delete, tar to move, git to version).
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
    echo "       If that run is orphaned (no launcher attached), remove it with:" >&2
    echo "         podman rm -f $cid" >&2
    exit 1
  fi
}
