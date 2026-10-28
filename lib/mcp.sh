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

# _mcp_copy SRC DEST - copy a single MCP config file into the staging dir. A plain
# file copy (not a tree), so there is no symlink walk as skills needs.
_mcp_copy() { cp "$1" "$2"; }

# collect_mcp - the single entry point the launcher calls. Resolves the file set into
# the container-side --strict-mcp-config/--mcp-config flag string (MCP_FLAGS), and on a
# real run copies each file into a staging dir and mounts it read-only at MCP_DEST. A
# missing/invalid selection aborts the launch, in dry-run too. Container file names are
# index-prefixed (00-, 01-, ...) so two files with the same basename never collide and
# array order (merge precedence) is preserved. Read-only is a bind mount (not file
# perms) so even container-root cannot mutate a file (see docs/containment-testing.md).
collect_mcp() {
  MCP_FLAGS=""; MCP_MOUNT=(); MCP_STAGING=""; MCP_FILES_LIST=""
  mcp_wanted || return 0
  local out; out="$(mcp_resolve)" || exit 1
  local -a files=(); local f
  while IFS= read -r f; do [[ -n "$f" ]] && files+=("$f"); done <<< "$out"

  # Strict is always on when an mcp block is present; [] yields strict with no servers.
  MCP_FLAGS="--strict-mcp-config"
  local -a names=(); local i=0 cname
  for f in "${files[@]:-}"; do
    [[ -n "$f" ]] || continue
    cname="$(printf '%02d-%s' "$i" "$(basename "$f")")"
    names+=("$cname")
    MCP_FLAGS+=" --mcp-config $MCP_DEST/$cname"
    i=$((i + 1))
  done
  MCP_FILES_LIST="${names[*]:-}"

  [[ "$DRY_RUN" == yes || ${#files[@]} -eq 0 ]] && return 0

  MCP_STAGING="$(mktemp -d)"
  i=0
  for f in "${files[@]}"; do
    _mcp_copy "$f" "$MCP_STAGING/${names[$i]}"
    i=$((i + 1))
  done
  register_target "$MCP_DEST" "mcp (read-only config)"
  MCP_MOUNT=(-v "$MCP_STAGING:$MCP_DEST:ro")
  printf 'Mounting (read-only): %d mcp config file(s) -> %s\n' "${#files[@]}" "$MCP_DEST" >&2
}
