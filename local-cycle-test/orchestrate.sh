#!/bin/bash
# orchestrate.sh - VISION.md -> design (omp + glm) -> code (omp + qwen)
# -> [review (omp + glm) <-> fix (omp + qwen)]* -> final review (Claude Code + cloud Claude).
# Every step is one agentdev one-shot run on the shared ./project workspace. Every step's
# file changes are committed to the project's git repo, so the history is the audit trail.
#
# Usage: ./orchestrate.sh path/to/VISION.md [max_cycles]
#   AGENTDEV=/path/to/agentdev   override the launcher (default: agentdev on PATH)
#   SKIP_FINAL=1                 stop after the local cycle (no cloud review)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="$HERE/project"
AGENTDEV="${AGENTDEV:-agentdev}"
DEFAULT_MAX_CYCLES=3

[[ $# -ge 1 && $# -le 2 ]] || { echo "usage: $0 VISION.md [max_cycles]" >&2; exit 2; }
VISION="$1"
MAX_CYCLES="${2:-$DEFAULT_MAX_CYCLES}"
[[ -f "$VISION" && -r "$VISION" ]] || { echo "Error: not a readable file: $VISION" >&2; exit 2; }
[[ "$MAX_CYCLES" =~ ^[1-9][0-9]*$ ]] || { echo "Error: max_cycles must be a positive integer: $MAX_CYCLES" >&2; exit 2; }
command -v "$AGENTDEV" >/dev/null || { echo "Error: agentdev not found (set AGENTDEV=...)" >&2; exit 2; }
# The profiles all point at ./project, so one run owns it; never build over an earlier result.
[[ ! -e "$PROJECT" ]] || { echo "Error: $PROJECT exists; move or remove it to start a new run." >&2; exit 2; }

LOGS="$HERE/runs/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOGS" "$PROJECT"
cp "$VISION" "$PROJECT/VISION.md"

git_p() { git -C "$PROJECT" -c user.name=orchestrate -c user.email=orchestrate@localhost "$@"; }
git_p init -q
git_p add -A && git_p commit -q -m "vision"

commit_step() {
  git_p add -A
  git_p diff --cached --quiet || git_p commit -q -m "$1"
}

# reseed_home SEED -> replace homes/SEED with a fresh copy of omp-seed/SEED (the local-only
# models.yml + config.yml), so every local step starts from the same clean omp home. The
# previous step's home is kept under the run's logs for inspection.
reseed_home() {
  local seed="$1" home="$HERE/homes/$1"
  if [[ -d "$home" ]]; then
    mkdir -p "$LOGS/homes"
    mv "$home" "$LOGS/homes/$seed-$(date +%H%M%S)"
  fi
  mkdir -p "$HERE/homes"
  cp -r "$HERE/omp-seed/$seed" "$home"
}

# run_step NAME PROFILE PROMPT [SEED] -> runs one agentdev one-shot; stdout to $LOGS/NAME.out.
run_step() {
  local name="$1" profile="$2" prompt="$3" seed="${4:-}" start rc=0
  [[ -z "$seed" ]] || reseed_home "$seed"
  start=$(date +%s)
  echo "==> $name  ($(basename "$profile"), $(basename "$prompt"))"
  "$AGENTDEV" -c "$HERE/$profile" --prompt "$HERE/$prompt" >"$LOGS/$name.out" 2>"$LOGS/$name.err" || rc=$?
  echo "    rc=$rc  $(( $(date +%s) - start ))s  log: $LOGS/$name.out"
  [[ $rc -eq 0 ]] || { echo "Error: step $name failed; see $LOGS/$name.err" >&2; exit 1; }
}

# verdict FILE -> APPROVED or CHANGES_REQUESTED. A missing verdict counts as changes
# requested, so a confused reviewer can never approve by accident.
verdict() {
  local v
  v=$(grep -oE 'VERDICT: (APPROVED|CHANGES_REQUESTED)' "$1" | tail -n1 | cut -d' ' -f2 || true)
  printf '%s\n' "${v:-CHANGES_REQUESTED}"
}

# A reviewer must not change the code. Its workspace is writable (it shares the design
# profile), so anything it changed is discarded before its review is recorded.
discard_reviewer_edits() {
  if [[ -n "$(git_p status --porcelain)" ]]; then
    echo "    warning: reviewer modified the workspace; discarding its edits"
    git_p status --porcelain > "$LOGS/$1.discarded"
    git_p checkout -q -- .
    git_p clean -q -fd
  fi
}

run_step design design-glm.json prompts/design.md glm
commit_step "design (omp + glm)"

run_step code code-qwen.json prompts/code.md qwen
commit_step "code (omp + qwen)"

result=CHANGES_REQUESTED
for (( cycle = 1; cycle <= MAX_CYCLES; cycle++ )); do
  run_step "review-$cycle" design-glm.json prompts/review.md glm
  discard_reviewer_edits "review-$cycle"
  cp "$LOGS/review-$cycle.out" "$PROJECT/REVIEW-$cycle.md"
  cp "$LOGS/review-$cycle.out" "$PROJECT/REVIEW.md"
  result=$(verdict "$PROJECT/REVIEW.md")
  commit_step "review $cycle (omp + glm): $result"
  echo "    verdict: $result"
  [[ "$result" == APPROVED ]] && break
  (( cycle < MAX_CYCLES )) || break
  run_step "fix-$cycle" code-qwen.json prompts/fix.md qwen
  commit_step "fix $cycle (omp + qwen)"
done
echo "local cycle finished: $result after $cycle review(s)"

if [[ "${SKIP_FINAL:-0}" == 1 ]]; then
  echo "SKIP_FINAL=1: no cloud review. Project: $PROJECT"
  exit 0
fi

run_step final-review review-claude.json prompts/final-review.md
cp "$LOGS/final-review.out" "$PROJECT/FINAL-REVIEW.md"
final=$(verdict "$PROJECT/FINAL-REVIEW.md")
commit_step "final review (claude code + cloud): $final"
echo "final verdict: $final"
echo "project: $PROJECT   history: git -C $PROJECT log --oneline   logs: $LOGS"
[[ "$final" == APPROVED ]]
