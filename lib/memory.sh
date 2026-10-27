#!/bin/bash
# memory.sh - the persistent memory layer and the deterministic project encoding.
# A memory store is a plain folder resolved (and created on first use) at launch;
# agentdev offers no management subcommands — manage the folders under MEMORY_ROOT
# yourself (and put one under git if you want history). Globals: MEMORY_ROOT, DIR_NAME.

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
