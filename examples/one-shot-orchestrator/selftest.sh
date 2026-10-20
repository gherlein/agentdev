#!/bin/bash
# selftest.sh — verify the orchestration plumbing end to end WITHOUT podman or the
# agentdev image, by pointing orchestrate.sh at the fake-agentdev shim.
set -euo pipefail
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
chmod +x "$SELF_DIR"/orchestrate.sh "$SELF_DIR"/worker.sh "$SELF_DIR"/fake-agentdev 2>/dev/null || true

CR=$(mktemp -d "${TMPDIR:-/tmp}/agentctl-selftest.XXXXXX")
trap 'rm -rf "$CR"' EXIT

echo "== running orchestrator against fake-agentdev =="
out=$(AGENTDEV="$SELF_DIR/fake-agentdev" CHANNEL_ROOT="$CR" MAXJOBS=3 \
      "$SELF_DIR/orchestrate.sh" "summarize X" "translate Y" "lint Z" "plan W" 2>&1) || {
        echo "$out"; echo "SELFTEST: orchestrator exited non-zero"; exit 1; }
echo "$out"
echo

echo "== checking results =="
fail=0
for run in w1 w2 w3 w4; do
  f="$CR/$run/out/result.txt"
  if [[ -s "$f" ]] && grep -q 'STUB RESULT' "$f"; then
    echo "  ok    $run result present + complete"
  else
    echo "  FAIL  $run result missing/incomplete ($f)"; fail=1
  fi
done

echo
if [[ $fail -eq 0 ]]; then echo "SELFTEST: PASS"; else echo "SELFTEST: FAIL"; exit 1; fi
