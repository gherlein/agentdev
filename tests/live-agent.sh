#!/bin/bash
# tests/live-agent.sh - Tier C of the testing plan: the one suite that drives a REAL
# agent (claude) making REAL model calls, to prove agentdev's persistence end to end:
#
#   1. mount a throwaway agent_folder as the agent's home,
#   2. run a one-shot agent that writes a secret into that home,
#   3. assert on the HOST that both the file and a session transcript (history) were
#      written into the agent_folder,
#   4. run a SECOND one-shot agent against the same agent_folder whose prompt can only
#      succeed by reading the secret the first run persisted.
#
# This costs real model usage. Auth is an API key: ANTHROPIC_API_KEY (from the host
# env) is written into a .env in the workspace, which the one-shot run loads. Skips
# cleanly (exit 0) when podman, the image, or ANTHROPIC_API_KEY is missing.
#
# Run: make test-live-agent   (or ./tests/live-agent.sh)
set -uo pipefail

REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
AD="$REPO/agentdev"
IMAGE="${IMAGE:-ghcr.io/gherlein/agentdev:latest}"
RUN_TIMEOUT="${RUN_TIMEOUT:-360}"
SECRET="CRIMSON-OTTER-7"

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); echo "  ok    $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL  $1"; [[ -n "${2:-}" ]] && printf '        | %s\n' "$2"; }
skip() { SKIP=$((SKIP+1)); echo "  skip  $1"; }

command -v podman >/dev/null || { echo "live-agent tests: podman not found; skipping."; exit 0; }
if ! podman image exists "$IMAGE"; then
  echo "live-agent tests: image '$IMAGE' not present (run 'make build'); skipping."; exit 0
fi
if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
  echo "live-agent tests: ANTHROPIC_API_KEY is unset; skipping."; exit 0
fi

ROOT="$(mktemp -d /tmp/agentdev-live-agent.XXXX)"
cleanup() {
  local lbl
  for lbl in agentdev.home agentdev.proxy; do
    timeout 30 podman ps -a --filter "label=$lbl" -q 2>/dev/null \
      | xargs -r timeout 30 podman rm -f >/dev/null 2>&1
  done
  rm -rf "$ROOT"
}
trap cleanup EXIT

WS="$ROOT/agentws"; mkdir -p "$WS"               # mounts at /agentws
printf 'ANTHROPIC_API_KEY=%s\n' "$ANTHROPIC_API_KEY" > "$WS/.env"   # loaded by the one-shot run
AHOME="$ROOT/home"                               # the persistent agent home
CFG="$ROOT/agentdev-config.json"

MEM_DIR_IN="/home/developer/.claude/agentdev-memory"
MEM_FILE_IN="$MEM_DIR_IN/secret.txt"
MEM_FILE_HOST="$AHOME/.claude/agentdev-memory/secret.txt"

cat > "$CFG" <<EOF
{
  "image":     "$IMAGE",
  "workspace": { "source": "$WS", "mount": "agentws" },
  "mounts":    { "agent_folder": "$AHOME" }
}
EOF

# agent_run PROMPT - one headless agent turn against the persistent home.
agent_run() {
  printf '%s\n' "$1" > "$ROOT/prompt.txt"
  ( timeout --kill-after=15 "$RUN_TIMEOUT" "$AD" -c "$CFG" --prompt "$ROOT/prompt.txt" </dev/null ) 2>&1
}

echo "== Tier C: live agent persistence (image: $IMAGE) =="

# Seed the home with a no-op run (creates an empty .claude), then pre-create the dir.
( timeout 60 "$AD" -c "$CFG" -- true ) >/dev/null 2>&1
mkdir -p "$AHOME/.claude/agentdev-memory"

echo "run 1: agent writes a secret into its home, leaving a transcript:"
out1=$(agent_run "Write exactly the text ${SECRET} to the file ${MEM_FILE_IN}, with no extra characters. Then stop.")

if grep -q "$SECRET" "$MEM_FILE_HOST" 2>/dev/null; then
  ok "file persisted into the agent home"
else
  bad "file persisted into the agent home" "expected $SECRET in $MEM_FILE_HOST; run1: $out1"
fi

if find "$AHOME/.claude/projects" -type f -name '*.jsonl' -size +0c 2>/dev/null | grep -q .; then
  ok "session transcript (history) persisted into the home"
else
  bad "session transcript (history) persisted into the home" \
      "no non-empty *.jsonl under $AHOME/.claude/projects"
fi

echo "run 2: a fresh agent must read the persisted file to answer:"
ANSWER_IN="/agentws/answer.txt"
run2() {
  agent_run "Read the file ${MEM_FILE_IN} and write ONLY its exact contents to ${ANSWER_IN}. Output nothing else."
}
out2=$(run2)
if ! grep -q "$SECRET" "$WS/answer.txt" 2>/dev/null; then
  rm -f "$WS/answer.txt"; out2=$(run2)
fi
if grep -q "$SECRET" "$WS/answer.txt" 2>/dev/null; then
  ok "second agent recalled the secret from the persisted home"
else
  bad "second agent recalled the secret from the persisted home" \
      "expected $SECRET in $WS/answer.txt (after one retry); run2: $out2"
fi

echo
echo "LIVE-AGENT: $PASS passed, $FAIL failed, $SKIP skipped"
[[ $FAIL -eq 0 ]]
