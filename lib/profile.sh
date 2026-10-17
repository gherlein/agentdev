#!/bin/bash
# profile.sh - resolve, lock, and manage profiles.
# Requires: git, flock; globals PROFILES_ROOT, CLEAN_ROOT, SELFDIR.

# new_run_id - a sortable, unique run identifier.
new_run_id() {
  printf '%s-%s\n' "$(date -u +%Y%m%dT%H%M%S)" "$(head -c4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
}

# lock_profile PATH - take an exclusive, non-blocking lock so a named profile
# cannot be launched twice at once. The lock releases when the launcher exits
# (the fd is held by the shell). Sets PROFILE_LOCK_FD.
lock_profile() {
  local path="$1"
  mkdir -p "$path"
  exec {PROFILE_LOCK_FD}>"$path/.agentdev.lock-file"
  if ! flock -n "$PROFILE_LOCK_FD"; then
    echo "Error: profile is already in use by another agentdev run: $path" >&2
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
      seed_profile; write_meta; write_lock; git_init_profile
      echo "Created profile: $PROFILE" ;;
    rm)
      rm -rf "${PROFILES_ROOT:?}/${1:?usage: profiles rm <name>}"; echo "removed profile: $1" ;;
    fork)
      local src="$PROFILES_ROOT/${1:?usage: profiles fork <src> <dst>}"
      local dst="$PROFILES_ROOT/${2:?usage: profiles fork <src> <dst>}"
      [[ -d "$src" ]] || { echo "no such profile: $1" >&2; return 1; }
      [[ -d "$dst" ]] && { echo "destination exists: $2" >&2; return 1; }
      cp -a "$src" "$dst"; echo "forked $1 -> $2" ;;
    snapshot)
      PROFILE="$PROFILES_ROOT/${1:?usage: profiles snapshot <name>}"; VCS=git
      snapshot_profile "manual snapshot"; echo "snapshotted: $1" ;;
    gc)
      # Sweep crashed clean-room leftovers.
      if [[ -d "$CLEAN_ROOT" ]]; then
        local n; n=$(find "$CLEAN_ROOT" -mindepth 1 -maxdepth 1 -type d | wc -l)
        rm -rf "${CLEAN_ROOT:?}"/*; echo "gc: swept $n clean-room leftover(s)"
      else
        echo "gc: nothing to sweep"
      fi ;;
    *) echo "Usage: agentdev profiles ls|show|new|rm|fork|snapshot|gc [args]" >&2; return 1 ;;
  esac
}

# cmd_diff - show the last run's footprint for a profile (defaults to most recent clean).
cmd_diff() {
  local p="${1:-}"
  if [[ -z "$p" ]]; then
    p=$(find "$CLEAN_ROOT" "$PROFILES_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null \
          -printf '%T@ %p\n' | sort -rn | head -1 | cut -d' ' -f2-)
  elif [[ ! -d "$p" ]]; then
    p="$PROFILES_ROOT/$p"
  fi
  [[ -d "$p/.git" ]] || { echo "no git-backed profile to diff: $p" >&2; return 1; }
  echo "# footprint of $p (working tree vs. last commit):"
  git -C "$p" --no-pager diff
  git -C "$p" --no-pager diff --stat HEAD
}
