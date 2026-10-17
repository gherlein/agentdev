#!/bin/bash
# memory.sh - the persistent memory layer and the deterministic project encoding.
# Requires: git; globals MEMORY_ROOT, DIR_NAME.

# compute_enc - Claude Code's projects/ directory name for the container workspace.
# The workspace is always the single top-level segment /<DIR_NAME>, so the encoding
# is "-" + DIR_NAME with "." replaced by "-". Asserted, not assumed.
compute_enc() {
  local name="$1"
  if [[ "$name" == *"/"* ]]; then
    echo "Error: workspace basename '$name' contains a slash; cannot encode." >&2
    exit 1
  fi
  ENC="-${name//./-}"
}

# resolve_memory_store NAME - resolve (create if missing) a git-backed store under
# MEMORY_ROOT. Sets MEMORY_STORE to the absolute path.
resolve_memory_store() {
  local name="${1:-default}"
  MEMORY_STORE="$MEMORY_ROOT/$name"
  if [[ ! -d "$MEMORY_STORE" ]]; then
    mkdir -p "$MEMORY_STORE"
    if [[ "$VCS" == "git" ]]; then
      git -C "$MEMORY_STORE" init -q
      git -C "$MEMORY_STORE" -c user.name=agentdev -c user.email=agentdev@localhost \
          commit -q --allow-empty -m "init memory store: $name" || true
    fi
    echo "Created memory store: $MEMORY_STORE" >&2
  fi
}

# snapshot_memory - commit what the agent learned this run.
snapshot_memory() {
  [[ "$VCS" == "git" ]] || return 0
  [[ -n "${MEMORY_STORE:-}" && -d "$MEMORY_STORE/.git" ]] || return 0
  git -C "$MEMORY_STORE" add -A
  if ! git -C "$MEMORY_STORE" diff --cached --quiet 2>/dev/null; then
    git -C "$MEMORY_STORE" -c user.name=agentdev -c user.email=agentdev@localhost \
        commit -q -m "${1:-memory update}" || true
  fi
}

# cmd_memory - the `agentdev memory …` subcommand surface.
cmd_memory() {
  local sub="${1:-ls}"; shift || true
  case "$sub" in
    ls)
      [[ -d "$MEMORY_ROOT" ]] || { echo "(no memory stores)"; return 0; }
      find "$MEMORY_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort ;;
    new)    resolve_memory_store "${1:?usage: memory new <name>}" ;;
    rm)     rm -rf "${MEMORY_ROOT:?}/${1:?usage: memory rm <name>}"; echo "removed memory store: $1" ;;
    diff)   git -C "$MEMORY_ROOT/${1:?usage: memory diff <name>}" diff ;;
    log)    git -C "$MEMORY_ROOT/${1:?usage: memory log <name>}" log --oneline ;;
    revert) git -C "$MEMORY_ROOT/${1:?usage: memory revert <name> <ref>}" revert --no-edit "${2:?need a ref}" ;;
    *) echo "Usage: agentdev memory ls|new|rm|diff|log|revert [name]" >&2; return 1 ;;
  esac
}
