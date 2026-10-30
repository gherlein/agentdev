#!/bin/bash
# pi-stages.sh - run the factory stages with pi, straight on the host, in one work directory that
# holds only VISION.md. Each stage runs only if the one before it finished cleanly.
#
#   ./pi-stages.sh WORK_DIR
#
# Stages: brainstorm (VISION.md -> REQUIREMENTS.md) -> designer (-> DESIGN.md) -> implementer
# (-> code + tests) -> make build && make test -> auditor (report judged by factory.sh's strict
# AUDIT: PASS gate). A stage is "ok" when pi exits 0, its last reply ended normally (not cut off
# by the token limit, not an error), and the file the stage exists to produce is there.
#
# Environment:
#   PI_CODING_AGENT_DIR  pi config dir (default ~/.pi/agent-router: the SGLang router on dgx1:4000)
#   MODEL                pi model (default router/qwen3.8-27b)
#   SKIP_AUDIT=1         stop after make test
#
# Logs go to WORK_DIR-logs/, outside the work directory so no agent reads them:
#   NN-stage.jsonl  pi's event stream (tail -f it to watch)   NN-stage.txt  the stage's last reply
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROMPTS="$HERE/prompts"
export PI_CODING_AGENT_DIR="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent-router}"
MODEL="${MODEL:-router/qwen3.8-27b}"

die() { echo "Error: $*" >&2; exit 2; }
[[ $# -eq 1 ]] || die "usage: $0 WORK_DIR"
[[ -d "$1" ]] || die "not a directory: $1"
WORK="$(cd "$1" && pwd)"
LOGS="$WORK-logs"
[[ -s "$WORK/VISION.md" ]] || die "$WORK/VISION.md is missing or empty"
[[ -f "$PI_CODING_AGENT_DIR/models.json" ]] || die "no pi config at $PI_CODING_AGENT_DIR/models.json"
command -v pi >/dev/null || die "pi not found on PATH"
command -v python3 >/dev/null || die "python3 is required"
mkdir -p "$LOGS"

log() { printf '%s  %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$LOGS/stages.log"; }
fail() { log "FAILED: $*"; exit 1; }

# last_reply JSONL TXT -> writes the final assistant text to TXT; prints its stopReason
# ("stop" when the model finished normally), or the error.
last_reply() {
  python3 -I - "$1" "$2" <<'EOF'
import json, sys
last = None
for line in open(sys.argv[1]):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    message = event.get("message") or {}
    if event.get("type") == "message_end" and message.get("role") == "assistant":
        last = message
if last is None:
    print("no-reply")
    sys.exit()
text = "".join(c.get("text", "") for c in last.get("content", []) if c.get("type") == "text")
open(sys.argv[2], "w").write(text.strip() + "\n")
print(last.get("errorMessage") or last.get("stopReason") or "unknown")
EOF
}

# stage N NAME THINKING [EXPECTED_FILE] -> one pi -p run of prompts/NAME.md in WORK.
stage() {
  local number="$1" name="$2" thinking="$3" expected="${4:-}" base status reason
  base="$LOGS/$number-$name"
  log "$name: start (thinking $thinking) -> tail -f $base.jsonl"
  set +e
  (cd "$WORK" && pi -p --mode json --model "$MODEL" --thinking "$thinking" \
    "@$PROMPTS/$name.md" "Begin." </dev/null) > "$base.jsonl" 2> "$base.stderr"
  status=$?
  set -e
  reason="$(last_reply "$base.jsonl" "$base.txt")"
  [[ $status -eq 0 ]] || fail "$name: pi exited $status (see $base.stderr)"
  [[ "$reason" == "stop" ]] || fail "$name: last reply ended with '$reason' (see $base.txt)"
  [[ -z "$expected" || -s "$WORK/$expected" ]] || fail "$name: $expected was not written"
  log "$name: ok"
}

log "work $WORK, model $MODEL, pi config $PI_CODING_AGENT_DIR"
stage 01 brainstorm  high REQUIREMENTS.md
stage 02 designer    high DESIGN.md
stage 03 implementer off  Makefile

log "verify: make build && make test"
(cd "$WORK" && make build && make test) > "$LOGS/04-verify.log" 2>&1 \
  || fail "verify: make build && make test failed (see $LOGS/04-verify.log)"
log "verify: ok"

[[ "${SKIP_AUDIT:-}" == 1 ]] && { log "audit skipped; done"; exit 0; }
stage 05 auditor high
# audit-verdict exits nonzero on GAPS; the verdict text is what decides.
verdict="$("$HERE/factory.sh" audit-verdict "$LOGS/05-auditor.txt")" || true
[[ "$verdict" == PASS ]] || fail "audit: gaps found (see $LOGS/05-auditor.txt)"
log "audit: PASS; done"
