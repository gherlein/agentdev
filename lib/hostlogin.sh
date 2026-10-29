#!/bin/bash
# hostlogin.sh - stage the operator's host claude login into the container for one run.
# With `"host_login": true`, agentdev copies the host's claude credentials file into a
# per-run staging dir and bind-mounts that copy read-write at the agent's credentials
# path, so claude inside is logged in with no .env, token, or hand-seeded home. The live
# file is never a mount source, and the copy is discarded on exit (see DESIGN-host-login.md).
#
# Read-write, single-file: claude's credential store rewrites the file in place
# (O_TRUNC, no rename), so a token refresh lands in the staged copy through the bind mount
# and never reaches the host file.
#
# Produces (collect_host_login): HOST_LOGIN_SRC (plan string), HOST_LOGIN_MOUNT (array),
# HOST_LOGIN_STAGING (path or empty), HOST_LOGIN_STUB (path or empty). Requires the config
# global HOST_LOGIN, MNT_AGENT_FOLDER, DRY_RUN, and register_target (mounts.sh). Staging
# side effects are skipped when DRY_RUN=yes.

HOST_LOGIN_DEST="/home/developer/.claude/.credentials.json"

# host_login_wanted -> 0 if the config opts in to staging the host login.
host_login_wanted() { [[ "${HOST_LOGIN:-false}" == true ]]; }

# host_login_source -> the host's claude credentials file, resolved the way claude
# resolves its own config dir ($CLAUDE_CONFIG_DIR, else ~/.claude).
host_login_source() { printf '%s/.credentials.json\n' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"; }

# collect_host_login - the single entry point the launcher calls. Fails closed (in
# dry-run too) when there is no readable login to stage. Messages name the path only,
# never the file's contents.
collect_host_login() {
  HOST_LOGIN_SRC=""; HOST_LOGIN_MOUNT=(); HOST_LOGIN_STAGING=""; HOST_LOGIN_STUB=""
  host_login_wanted || return 0
  HOST_LOGIN_SRC="$(host_login_source)"
  if [[ ! -f "$HOST_LOGIN_SRC" || ! -r "$HOST_LOGIN_SRC" ]]; then
    echo "Error: host_login: no claude login found at $HOST_LOGIN_SRC; log in with claude on the host first." >&2
    exit 1
  fi
  register_target "$HOST_LOGIN_DEST" "host_login"

  [[ "$DRY_RUN" == yes ]] && return 0

  HOST_LOGIN_STAGING="$(mktemp -d)"
  install -m 600 "$HOST_LOGIN_SRC" "$HOST_LOGIN_STAGING/.credentials.json"
  # A persistent home with no credentials of its own gets an empty mount-point stub from
  # the runtime; remember it so cleanup can remove it. A home's own non-empty credentials
  # file is hidden for the run and never touched.
  if [[ -n "$MNT_AGENT_FOLDER" && ! -s "$MNT_AGENT_FOLDER/.claude/.credentials.json" ]]; then
    HOST_LOGIN_STUB="$MNT_AGENT_FOLDER/.claude/.credentials.json"
  fi
  HOST_LOGIN_MOUNT=(-v "$HOST_LOGIN_STAGING/.credentials.json:$HOST_LOGIN_DEST:rw")
  echo "Mounting (read-write): host claude login (per-run copy) -> $HOST_LOGIN_DEST" >&2
}

# host_login_cleanup - discard the staged copy, and the empty mount-point stub if this
# run left one behind in a persistent home.
host_login_cleanup() {
  rm -rf "${HOST_LOGIN_STAGING:-}"
  if [[ -n "${HOST_LOGIN_STUB:-}" && -f "$HOST_LOGIN_STUB" && ! -s "$HOST_LOGIN_STUB" ]]; then
    rm -f "$HOST_LOGIN_STUB"
  fi
  return 0
}
