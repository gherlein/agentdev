#!/bin/bash
# memory.sh - the persistent memory layer and the deterministic project encoding.
# A memory store is a plain folder; agentdev never versions it. If you want history,
# put the store under git (or anything else) yourself. Globals: MEMORY_ROOT, DIR_NAME.

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

# resolve_memory_store NAME - resolve (create if missing) a plain store folder under
# MEMORY_ROOT. Sets MEMORY_STORE to the absolute path.
resolve_memory_store() {
  local name="${1:-default}"
  MEMORY_STORE="$MEMORY_ROOT/$name"
  if [[ ! -d "$MEMORY_STORE" ]]; then
    mkdir -p "$MEMORY_STORE"
    echo "Created memory store: $MEMORY_STORE" >&2
  fi
}

# cmd_memory - the `agentdev memory …` subcommand surface. Versioning (diff/log/revert)
# is intentionally absent: run git yourself against $MEMORY_ROOT/<name> if you want it.
cmd_memory() {
  local sub="${1:-ls}"; shift || true
  case "$sub" in
    ls)
      [[ -d "$MEMORY_ROOT" ]] || { echo "(no memory stores)"; return 0; }
      find "$MEMORY_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort ;;
    new)    resolve_memory_store "${1:?usage: memory new <name>}" ;;
    rm)     rm -rf "${MEMORY_ROOT:?}/${1:?usage: memory rm <name>}"; echo "removed memory store: $1" ;;
    *) echo "Usage: agentdev memory ls|new|rm [name]" >&2; return 1 ;;
  esac
}
