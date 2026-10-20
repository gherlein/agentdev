#!/bin/bash
# orchestrate.sh — a minimal "master" that fans out one-shot agentdev runs and
# collects each result as a file.
#
# Model (see ../../docs/managing-context-and-memory.md and DESIGN.md §2.5):
#   - ONE clean agentdev container per task — each gets its own throwaway home,
#     takes no profile lock, and so runs fully concurrently;
#   - data comes back through a per-run CHANNEL dir bind-mounted via `-rw`, which
#     lands at /external/<run> inside the container;
#   - the COMPLETION SIGNAL is the child process exiting: agentdev runs `podman
#     run --rm` in the foreground, so the launcher (our child) lives exactly as
#     long as the container. When `wait` returns, we read out/result.txt.
#
# Nothing runs in the background inside the container — for the one-shot model
# the exit is the trigger and the file is the payload.
set -euo pipefail

AGENTDEV="${AGENTDEV:-agentdev}"                    # override to a shim for selftest
# If AGENTDEV is given as a path, resolve it absolutely: each child cd's to
# $WORKSPACE before exec, so a relative path would stop resolving there.
[[ "$AGENTDEV" == */* ]] && AGENTDEV=$(realpath "$AGENTDEV")
MAXJOBS="${MAXJOBS:-4}"                             # max concurrent containers
AUTH="${AGENTDEV_AUTH:-api-key-env}"                # headless needs a key, not login
CHANNEL_ROOT="${CHANNEL_ROOT:-$(mktemp -d "${TMPDIR:-/tmp}/agentctl.XXXXXX")}"
WORKSPACE="${WORKSPACE:-$(mktemp -d "${TMPDIR:-/tmp}/agentws.XXXXXX")}"
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

usage(){ echo "usage: $0 <tasks-file> | $0 \"task one\" \"task two\" ..." >&2; exit 2; }
[[ $# -ge 1 ]] || usage

# Tasks: a single existing file (one task per line) or literal args.
tasks=()
if [[ $# -eq 1 && -f "$1" ]]; then
  mapfile -t tasks < <(grep -vE '^[[:space:]]*($|#)' "$1")
else
  tasks=("$@")
fi
[[ ${#tasks[@]} -gt 0 ]] || { echo "no tasks" >&2; exit 2; }

echo "channel root: $CHANNEL_ROOT"
echo "workspace:    $WORKSPACE"
echo "tasks:        ${#tasks[@]}   maxjobs: $MAXJOBS   agentdev: $AGENTDEV"
echo

declare -A RUN_OF        # pid -> run id
LAST_PID=""

launch_one() {           # launch_one <n> <task> ; sets LAST_PID
  local n="$1" task="$2" run="w$1" dir
  dir="$CHANNEL_ROOT/$run"
  mkdir -p "$dir/in" "$dir/out" "$dir/bin"
  cp "$SELF_DIR/worker.sh" "$dir/bin/worker.sh"
  printf '%s' "$task" > "$dir/in/task.txt"
  # `-rw $dir` → /external/$run in the container (agentdev's basename rule).
  (
    cd "$WORKSPACE"
    exec "$AGENTDEV" --clean --auth "$AUTH" -rw "$dir" \
         -- bash "/external/$run/bin/worker.sh"
  ) > "$dir/out/agentdev.log" 2>&1 &
  LAST_PID=$!
  RUN_OF[$LAST_PID]="$run"
  echo "  spawned $run (pid $LAST_PID): ${task:0:60}"
}

collect_one() {          # collect_one <run> <exit-code>
  local run="$1" rc="$2" dir="$CHANNEL_ROOT/$1"
  if [[ "$rc" -eq 0 && -f "$dir/out/result.txt" ]]; then
    echo "  OK    $run  -> $dir/out/result.txt ($(wc -c < "$dir/out/result.txt") bytes)"
  else
    echo "  FAIL  $run  (exit $rc)  see $dir/out/agentdev.log, $dir/out/stderr.log"
  fi
}

# Batch launches so no more than MAXJOBS containers run at once. Within a batch,
# `wait $pid` returns each child's real exit status (no job is reaped early).
i=0; total=${#tasks[@]}
while (( i < total )); do
  pids=()
  for (( j=0; j<MAXJOBS && i<total; j++, i++ )); do
    launch_one "$((i+1))" "${tasks[$i]}"
    pids+=("$LAST_PID")
  done
  for pid in "${pids[@]}"; do
    rc=0; wait "$pid" || rc=$?
    collect_one "${RUN_OF[$pid]}" "$rc"
  done
done

echo
echo "done. results under: $CHANNEL_ROOT/*/out/result.txt"
