#!/bin/bash
# factory.sh - run the pngdec software-factory test through agentdev, and score it with the
# frozen anchor suite.
#
#   ./factory.sh selftest          prove the scorer: reference = all pass, a fake binary does not
#   ./factory.sh run [LABEL]       one pipeline run -> runs/<timestamp>[-LABEL]/, then score it
#   ./factory.sh score RUN_DIR     (re)build and (re)score an existing run
#   ./factory.sh results           table of every run under runs/
#
# Pipeline: brainstorm (glm) -> designer (glm) -> implementer (qwen) -> verify loop
# -> audit loop [auditor (glm, read-only) -> fixer (qwen) -> verify]. This script is the
# "lead": stage order and every budget are enforced here, not in a prompt.
#
# Budgets and caps (environment):
#   VERIFY_RETRIES  fixer attempts after a failed `make build && make test` (default 3)
#   AUDIT_CYCLES    auditor rounds before giving up (default 3)
#   RUN_TIMEOUT     wall-clock cap on agent work + in-band verify, seconds (default 5400 = 90 min)
#   VERIFY_TIMEOUT  cap on one verify, seconds (default 600)
#   AGENTDEV        launcher (default: ../agentdev, then agentdev on PATH)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFY_RETRIES="${VERIFY_RETRIES:-3}"
AUDIT_CYCLES="${AUDIT_CYCLES:-3}"
RUN_TIMEOUT="${RUN_TIMEOUT:-5400}"
VERIFY_TIMEOUT="${VERIFY_TIMEOUT:-600}"
# Seconds a step gets after TERM before it is killed.
KILL_GRACE=60
# Lines of failing verify output handed to the fixer.
FAILURE_TAIL_LINES=200
TIMEOUT_EXIT=124

if [[ -n "${AGENTDEV:-}" ]]; then :
elif [[ -x "$HERE/../agentdev" ]]; then AGENTDEV="$HERE/../agentdev"
else AGENTDEV=agentdev; fi

die() { echo "Error: $*" >&2; exit 2; }
for v in VERIFY_RETRIES AUDIT_CYCLES RUN_TIMEOUT VERIFY_TIMEOUT; do
  [[ "${!v}" =~ ^[0-9]+$ ]] || die "$v must be a non-negative integer: ${!v}"
done
command -v "$AGENTDEV" >/dev/null || die "agentdev not found (set AGENTDEV=...)"
command -v python3 >/dev/null || die "python3 is required on the host"

# --- run directory ---------------------------------------------------------------------

# new_run_dir PREFIX -> a fresh runs/ dir holding this run's copy of every profile, so the
# profiles' relative paths (./work, ./homes, ../../task) resolve inside it.
new_run_dir() {
  local dir="$HERE/runs/$1"
  [[ ! -e "$dir" ]] || die "$dir already exists"
  mkdir -p "$dir/work" "$dir/score" "$dir/logs" "$dir/prompts" "$dir/homes"
  cp "$HERE"/profiles/*.json "$dir/"
  printf '%s\n' "$dir"
}

# --- steps -----------------------------------------------------------------------------

# remaining -> seconds left on the run clock (0 when exhausted).
remaining() {
  local left=$(( DEADLINE - $(date +%s) ))
  (( left > 0 )) && printf '%s\n' "$left" || printf '0\n'
}

# record NAME PROFILE RC SECONDS -> one timeline row.
record() { printf '%s\t%s\t%s\t%s\n' "$@" >> "$RUN/timeline.tsv"; }

# reseed HOME SEED -> a clean omp home for the next step; the spent one is kept in logs/.
reseed() {
  local home="$RUN/homes/$1"
  if [[ -d "$home" ]]; then mv "$home" "$RUN/logs/home-$1-$(date +%H%M%S)"; fi
  cp -r "$HERE/omp-seed/$2" "$home"
}

# agent_step NAME PROFILE HOME SEED PROMPT_FILE -> one agentdev one-shot under the run clock.
# Sets STEP_RC. A step that hits the clock leaves STEP_RC=124.
agent_step() {
  local name="$1" profile="$2" home="$3" seed="$4" prompt="$5" left start
  left=$(remaining)
  if (( left == 0 )); then STEP_RC=$TIMEOUT_EXIT; record "$name" "$profile" "$STEP_RC" 0; return; fi
  reseed "$home" "$seed"
  start=$(date +%s); STEP_RC=0
  echo "==> $name ($profile; ${left}s left on the clock)"
  timeout --signal=TERM --kill-after="$KILL_GRACE" "$left" \
    "$AGENTDEV" -c "$RUN/$profile.json" --prompt "$prompt" \
    >"$RUN/logs/$name.out" 2>"$RUN/logs/$name.err" || STEP_RC=$?
  record "$name" "$profile" "$STEP_RC" $(( $(date +%s) - start ))
  echo "    rc=$STEP_RC $(( $(date +%s) - start ))s"
  snapshot "$name"
}

# verify NAME -> `make build && make test` in the network-less sandbox, under the run clock.
# Sets STEP_RC (0 = passed).
verify() {
  local name="$1" left cap start
  left=$(remaining)
  if (( left == 0 )); then STEP_RC=$TIMEOUT_EXIT; record "$name" sandbox "$STEP_RC" 0; return; fi
  cap=$(( left < VERIFY_TIMEOUT ? left : VERIFY_TIMEOUT ))
  start=$(date +%s); STEP_RC=0
  echo "==> $name (make build && make test)"
  timeout --signal=TERM --kill-after="$KILL_GRACE" "$cap" \
    "$AGENTDEV" -c "$RUN/sandbox.json" -- bash -lc 'make build && make test' \
    >"$RUN/logs/$name.out" 2>"$RUN/logs/$name.err" || STEP_RC=$?
  # A verify cut short by its own cap is a failure; one cut short by the run clock is a cap.
  if (( STEP_RC == TIMEOUT_EXIT )) && (( $(remaining) > 0 )); then STEP_RC=1; fi
  record "$name" sandbox "$STEP_RC" $(( $(date +%s) - start ))
  echo "    rc=$STEP_RC"
}

# fixer_prompt NAME REPORT_FILE -> a prompt file: fixer.md followed by the report.
fixer_prompt() {
  local out="$RUN/prompts/$1.md"
  { cat "$HERE/prompts/fixer.md"; echo; cat "$2"; } > "$out"
  printf '%s\n' "$out"
}

# The step history lives outside the workspace (history.git), so the agents see exactly what
# the erg pipeline's agents saw: VISION.md and their own files.
git_h() { git --git-dir="$RUN/history.git" --work-tree="$RUN/work" \
            -c user.name=factory -c user.email=factory@localhost "$@"; }
snapshot() {
  git_h add -A
  git_h diff --cached --quiet || git_h commit -q -m "$1"
}

# verify_loop TAG -> verify, and on failure hand the output to the fixer, up to
# VERIFY_RETRIES fixes. Sets LOOP_RESULT to pass | fail | capped.
verify_loop() {
  local tag="$1" attempt
  for (( attempt = 0; attempt <= VERIFY_RETRIES; attempt++ )); do
    verify "verify-$tag-$attempt"
    (( STEP_RC == 0 )) && { LOOP_RESULT=pass; return; }
    (( STEP_RC == TIMEOUT_EXIT )) && { LOOP_RESULT=capped; return; }
    (( attempt < VERIFY_RETRIES )) || break
    tail -n "$FAILURE_TAIL_LINES" "$RUN/logs/verify-$tag-$attempt.out" "$RUN/logs/verify-$tag-$attempt.err" \
      > "$RUN/logs/verify-$tag-$attempt.report"
    agent_step "fix-verify-$tag-$attempt" coder coder qwen \
      "$(fixer_prompt "fix-verify-$tag-$attempt" "$RUN/logs/verify-$tag-$attempt.report")"
    (( STEP_RC == TIMEOUT_EXIT )) && { LOOP_RESULT=capped; return; }
  done
  LOOP_RESULT=fail
}

# audit_passed REPORT -> 0 if the report's last non-empty line is exactly "AUDIT: PASS".
# A report with no verdict is a gap, so a confused auditor can never pass a run by accident.
audit_passed() {
  [[ "$(grep -v '^[[:space:]]*$' "$1" | tail -n 1 | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')" == "AUDIT: PASS" ]]
}

# --- commands --------------------------------------------------------------------------

cmd_run() {
  local label="${1:-}" id cycle stage
  id="$(date +%Y%m%d-%H%M%S)${label:+-$label}"
  [[ -z "$label" || "$label" =~ ^[A-Za-z0-9._-]+$ ]] || die "label must be [A-Za-z0-9._-]: $label"
  RUN="$(new_run_dir "$id")"
  cp "$HERE/task/VISION.md" "$RUN/work/VISION.md"
  git init -q --bare "$RUN/history.git"
  snapshot "vision"
  write_meta_start
  START=$(date +%s); DEADLINE=$(( START + RUN_TIMEOUT ))
  OUTCOME=""; AUDITS=0

  for stage in "brainstorm reasoner reasoner glm REQUIREMENTS.md" \
               "designer reasoner reasoner glm DESIGN.md"; do
    set -- $stage
    agent_step "$1" "$2" "$3" "$4" "$HERE/prompts/$1.md"
    (( STEP_RC == TIMEOUT_EXIT )) && { OUTCOME=capped; break; }
    [[ -s "$RUN/work/$5" ]] || { OUTCOME="no-$5"; break; }
  done

  if [[ -z "$OUTCOME" ]]; then
    agent_step implementer coder coder qwen "$HERE/prompts/implementer.md"
    (( STEP_RC == TIMEOUT_EXIT )) && OUTCOME=capped
  fi
  if [[ -z "$OUTCOME" ]]; then
    verify_loop initial
    case "$LOOP_RESULT" in capped) OUTCOME=capped ;; fail) OUTCOME=verify-failed ;; esac
  fi
  if [[ -z "$OUTCOME" ]]; then
    for (( cycle = 1; cycle <= AUDIT_CYCLES; cycle++ )); do
      AUDITS=$cycle
      agent_step "audit-$cycle" auditor auditor glm "$HERE/prompts/auditor.md"
      (( STEP_RC == TIMEOUT_EXIT )) && { OUTCOME=capped; break; }
      cp "$RUN/logs/audit-$cycle.out" "$RUN/logs/audit-$cycle.report"
      audit_passed "$RUN/logs/audit-$cycle.report" && { OUTCOME=completed; break; }
      (( cycle < AUDIT_CYCLES )) || { OUTCOME=audit-budget-exhausted; break; }
      agent_step "fix-audit-$cycle" coder coder qwen \
        "$(fixer_prompt "fix-audit-$cycle" "$RUN/logs/audit-$cycle.report")"
      (( STEP_RC == TIMEOUT_EXIT )) && { OUTCOME=capped; break; }
      verify_loop "audit-$cycle"
      case "$LOOP_RESULT" in capped) OUTCOME=capped; break ;; fail) OUTCOME=verify-failed; break ;; esac
    done
  fi
  AGENT_SECONDS=$(( $(date +%s) - START ))
  echo "pipeline: $OUTCOME after ${AGENT_SECONDS}s ($AUDITS audit round(s))"
  write_meta_end
  score_run "$RUN"
}

# score_run RUN_DIR -> post-clock build in the sandbox, then the anchor suite in the scorer.
score_run() {
  RUN="$(cd "$1" && pwd)"
  [[ -f "$RUN/scorer.json" && -d "$RUN/work" ]] || die "not a run directory: $1"
  rm -f "$RUN/score/anchor.json" "$RUN/score.json"
  echo "==> post-run build (off the clock)"
  "$AGENTDEV" -c "$RUN/sandbox.json" -- bash -lc 'make build' \
    >"$RUN/logs/final-build.out" 2>"$RUN/logs/final-build.err" || true
  echo "==> anchor score"
  "$AGENTDEV" -c "$RUN/scorer.json" -- bash -lc 'make -s -f /scorer/Makefile anchor BIN=/candidate/pngdec OUT=/out' \
    >"$RUN/logs/score.out" 2>"$RUN/logs/score.err" || true
  if [[ -s "$RUN/score/anchor.json" ]]; then
    python3 -I "$HERE/lib/anchor_score.py" "$RUN/score/anchor.json" "$RUN/score.json"
  else
    printf '{"passed": 0, "total": null, "failed_cases": [], "suite_build_failed": false, "no_binary": true}\n' > "$RUN/score.json"
    echo "anchor: no binary (post-run build failed; see $RUN/logs/final-build.err)"
  fi
}

cmd_selftest() {
  local ref fake
  RUN="$(new_run_dir "selftest-$(date +%Y%m%d-%H%M%S)")"
  echo "==> reference binary must pass every case"
  "$AGENTDEV" -c "$RUN/scorer.json" -- bash -lc \
    'make -s -f /scorer/Makefile reference OUT=/out && make -s -f /scorer/Makefile anchor BIN=/out/pngdec OUT=/out' \
    >"$RUN/logs/reference.out" 2>"$RUN/logs/reference.err" || true
  python3 -I "$HERE/lib/anchor_score.py" "$RUN/score/anchor.json" "$RUN/score-reference.json"
  echo "==> a fake binary (always '{}', exit 0) must not"
  printf '#!/bin/sh\necho "{}"\n' > "$RUN/work/pngdec"; chmod +x "$RUN/work/pngdec"
  "$AGENTDEV" -c "$RUN/scorer.json" -- bash -lc 'make -s -f /scorer/Makefile anchor BIN=/candidate/pngdec OUT=/out' \
    >"$RUN/logs/fake.out" 2>"$RUN/logs/fake.err" || true
  python3 -I "$HERE/lib/anchor_score.py" "$RUN/score/anchor.json" "$RUN/score-fake.json"
  python3 -I - "$RUN/score-reference.json" "$RUN/score-fake.json" <<'EOF'
import json, sys
ref, fake = (json.load(open(p)) for p in sys.argv[1:3])
ok = ref["total"] > 0 and ref["passed"] == ref["total"] and fake["passed"] < ref["total"]
print("selftest: %s (reference %d/%d, fake %d/%d)" % (
    "PASS" if ok else "FAIL", ref["passed"], ref["total"], fake["passed"], fake["total"]))
sys.exit(0 if ok else 1)
EOF
}

cmd_results() {
  python3 -I "$HERE/lib/results.py" "$HERE/runs"
}

# --- metadata --------------------------------------------------------------------------

write_meta_start() {
  python3 -I - "$RUN/meta.json" <<EOF
import json, sys
json.dump({
  "run": "$(basename "$RUN")",
  "started": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "agentdev_commit": "$(git -C "$HERE/.." rev-parse --short HEAD 2>/dev/null || echo unknown)",
  "image": "$(podman image inspect --format '{{.Id}}' "$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["image"])' "$RUN/coder.json")" 2>/dev/null | cut -c1-12)",
  "task_sha256": "$(cd "$HERE/task" && find . -type f | sort | xargs sha256sum | sha256sum | cut -c1-16)",
  "models": {"reasoner": "glm-4.5-air", "auditor": "glm-4.5-air", "coder": "local-qwen"},
  "agent": "omp",
  "budgets": {"verify_retries": $VERIFY_RETRIES, "audit_cycles": $AUDIT_CYCLES,
              "run_timeout_s": $RUN_TIMEOUT, "verify_timeout_s": $VERIFY_TIMEOUT},
}, open(sys.argv[1], "w"), indent=2)
EOF
}

write_meta_end() {
  python3 -I - "$RUN/meta.json" "$RUN/timeline.tsv" "$OUTCOME" "$AGENT_SECONDS" "$AUDITS" <<'EOF'
import json, sys
path, timeline, outcome, seconds, audits = sys.argv[1:6]
meta = json.load(open(path))
steps = []
for line in open(timeline):
    name, profile, rc, secs = line.rstrip("\n").split("\t")
    steps.append({"step": name, "profile": profile, "rc": int(rc), "seconds": int(secs)})
meta.update({"outcome": outcome, "agent_seconds": int(seconds), "audit_rounds": int(audits),
             "steps": steps})
json.dump(meta, open(path, "w"), indent=2)
EOF
}

case "${1:-}" in
  run)      shift; cmd_run "$@" ;;
  selftest) cmd_selftest ;;
  score)    [[ $# -eq 2 ]] || die "usage: $0 score RUN_DIR"; score_run "$2" ;;
  results)  cmd_results ;;
  *)        sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
