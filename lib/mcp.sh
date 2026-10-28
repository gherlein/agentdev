#!/bin/bash
# mcp.sh - materialize a controlled set of MCP server definitions into the container
# and wire the agent to load only them. An `mcp` block (an array of host paths to MCP
# config files) names the files this run may use. agentdev resolves and validates the
# list, copies the files into a per-run staging dir mounted read-only, and emits the
# --strict-mcp-config / --mcp-config flags. Under strict mode Claude loads only these
# files and ignores every other scope (user, project, local), so the array is a true
# allowlist for the one-shot (headless) path.
#
# Config is the source of truth: the set is recomputed every launch and nothing
# persists. Read-only is a bind mount, not file permissions, because the agent can
# reach container-root and would defeat permission-based immutability (see
# docs/containment-testing.md).
#
# Produces (collect_mcp, added in a later step): MCP_FLAGS (container-side flag string),
# MCP_MOUNT (array), MCP_STAGING (path or empty), MCP_FILES_LIST (plan string). Requires
# the config globals MCP_PRESENT/MCP_FILES, anchor_path (config.sh), DRY_RUN, and
# register_target (mounts.sh). Staging/copy side effects are skipped when DRY_RUN=yes.

MCP_DEST="/home/developer/.agentdev-mcp"

# mcp_wanted -> 0 if an mcp block is present (an array of files, or [] for deny-all).
mcp_wanted() { [[ "${MCP_PRESENT:-no}" == yes ]]; }

# _mcp_validate_file FILE -> 0 if FILE is valid JSON with a top-level mcpServers object.
# The file's contents are never echoed, so a stray literal secret cannot leak into a
# log; the message carries the path only (MCP01).
_mcp_validate_file() {
  local f="$1"
  python3 -I -c 'import json,sys; json.load(open(sys.argv[1]))' "$f" 2>/dev/null \
    || { echo "Error: mcp '$f': not valid JSON" >&2; return 1; }
  python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if isinstance(d.get("mcpServers"),dict) else 1)' "$f" \
    || { echo "Error: mcp '$f': missing a top-level \"mcpServers\" object" >&2; return 1; }
}

# mcp_resolve - print the resolved absolute host path of each listed file (one per
# line). Empty output with status 0 for [] (deny-all). Returns non-zero (fail-closed)
# on a missing/unreadable/non-file path or a malformed/no-mcpServers file.
mcp_resolve() {
  mcp_wanted || return 0
  local f rf
  for f in "${MCP_FILES[@]:-}"; do
    [[ -n "$f" ]] || continue
    rf="$(anchor_path "$f")"
    [[ -f "$rf" && -r "$rf" ]] || { echo "Error: mcp '$f': not an existing readable file ($rf)" >&2; return 1; }
    _mcp_validate_file "$rf" || return 1
    printf '%s\n' "$rf"
  done
  return 0
}
