#!/bin/bash
# worker.sh — runs INSIDE the agentdev container as the one-shot command.
#
# It reads the task from the channel's in/, runs the agent, and publishes the
# answer to out/result.txt with an ATOMIC rename. The master only reacts after
# this process exits, but the atomic publish also means a watcher (if you add
# one) never sees a half-written file.
set -euo pipefail

# The channel dir is the parent of this script's bin/ dir. In the container the
# path is /external/<run>/bin/worker.sh, so CH resolves to /external/<run>.
CH=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
IN="$CH/in"; OUT="$CH/out"
mkdir -p "$OUT"

task=$(cat "$IN/task.txt")

tmp=$(mktemp "$OUT/.result.XXXXXX")
trap 'rm -f "$tmp"' EXIT

if [[ "${AGENT_STUB:-0}" == 1 ]]; then
  # Used by selftest.sh — no real agent, just a deterministic stand-in.
  printf 'STUB RESULT\ntask: %s\npid: %s\n' "$task" "$$" > "$tmp"
else
  # The real one-shot: headless Claude Code. Its stdout is the answer.
  #
  # The sample tasks only READ, so plain `claude -p` is enough. For an AUTONOMOUS
  # task that EDITS files ("implement the code"), add --dangerously-skip-permissions
  # (or --permission-mode acceptEdits) here — otherwise the run stalls on approval
  # prompts. The container's `clauded` alias does NOT apply: this is exec'd directly,
  # not an interactive shell.
  if ! claude -p "$task" > "$tmp" 2> "$OUT/stderr.log"; then
    cp "$tmp" "$OUT/partial.txt" 2>/dev/null || true
    echo "agent failed; see $OUT/stderr.log" >&2
    exit 1
  fi
fi

mv -f "$tmp" "$OUT/result.txt"   # atomic publish within the same dir/fs
trap - EXIT
