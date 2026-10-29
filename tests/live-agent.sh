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
# This costs real model usage. Auth prefers the operator's own subscription via
# "host_login": true, so agentdev stages a per-run copy of the host claude login and this
# suite doubles as the end-to-end proof of that feature. Only the credentials file crosses
# (never the operator's projects/ or history), so the persistence assertions below stay
# honest. With no host login, it falls back to ANTHROPIC_API_KEY written into a .env in the
# workspace. Skips cleanly (exit 0) when podman, the image, or any usable credential
# (${CLAUDE_CONFIG_DIR:-~/.claude}/.credentials.json or ANTHROPIC_API_KEY) is missing.
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
# Credentials: prefer the operator's host login (staged by host_login), else an API key.
# Resolved the way agentdev and claude resolve it.
HAVE_OAUTH=no; [[ -f "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json" ]] && HAVE_OAUTH=yes
HAVE_KEY=no;   [[ -n "${ANTHROPIC_API_KEY:-}" ]] && HAVE_KEY=yes
if [[ "$HAVE_OAUTH" == no && "$HAVE_KEY" == no ]]; then
  echo "live-agent tests: no usable credentials (~/.claude/.credentials.json or ANTHROPIC_API_KEY); skipping."
  exit 0
fi

ROOT="$(mktemp -d /tmp/agentdev-live-agent.XXXX)"
chmod 700 "$ROOT"
. "$(dirname "${BASH_SOURCE[0]}")/cleanup.sh"
PROXIES_BEFORE="$(agentdev_proxy_ids)"
cleanup() {
  remove_own_containers "$ROOT" "$PROXIES_BEFORE"
  rm -rf "$ROOT"
}
trap cleanup EXIT
# A fallback API key in the workspace .env must be removed even on an interrupt during
# the long agent run: these handlers exit, which fires the EXIT trap above.
trap 'exit 130' INT
trap 'exit 143' TERM HUP

WS="$ROOT/agentws"; mkdir -p "$WS"               # mounts at /agentws
# The API key is the fallback only; with a host login, host_login authenticates the run.
[[ "$HAVE_OAUTH" == no && "$HAVE_KEY" == yes ]] && printf 'ANTHROPIC_API_KEY=%s\n' "$ANTHROPIC_API_KEY" > "$WS/.env"
AHOME="$ROOT/home"                               # the persistent agent home
CFG="$ROOT/agentdev-config.json"
HOST_LOGIN=false; [[ "$HAVE_OAUTH" == yes ]] && HOST_LOGIN=true

MEM_DIR_IN="/home/developer/.claude/agentdev-memory"
MEM_FILE_IN="$MEM_DIR_IN/secret.txt"
MEM_FILE_HOST="$AHOME/.claude/agentdev-memory/secret.txt"

cat > "$CFG" <<EOF
{
  "image":     "$IMAGE",
  "workspace": { "source": "$WS", "mount": "agentws" },
  "mounts":    { "agent_folder": "$AHOME" },
  "host_login": $HOST_LOGIN
}
EOF

# agent_run PROMPT - one headless agent turn against the persistent home.
agent_run() {
  printf '%s\n' "$1" > "$ROOT/prompt.txt"
  ( timeout --kill-after=15 "$RUN_TIMEOUT" "$AD" -c "$CFG" --prompt "$ROOT/prompt.txt" </dev/null ) 2>&1
}

echo "== Tier C: live agent persistence (image: $IMAGE) =="
echo "   auth: $([[ "$HAVE_OAUTH" == yes ]] && echo 'host_login (per-run copy of the host claude login)' || echo 'ANTHROPIC_API_KEY via workspace .env')"

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

if [[ "$HOST_LOGIN" == true ]]; then
  if [[ ! -e "$AHOME/.claude/.credentials.json" ]]; then
    ok "host login never persisted into the agent home"
  else
    bad "host login never persisted into the agent home" \
        "$AHOME/.claude/.credentials.json exists ($(stat -c %s "$AHOME/.claude/.credentials.json") bytes)"
  fi
fi

echo
echo "LIVE-AGENT: $PASS passed, $FAIL failed, $SKIP skipped"
[[ $FAIL -eq 0 ]]
