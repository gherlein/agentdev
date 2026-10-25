#!/bin/bash
# tests/live-agent.sh - Tier C of the testing plan: the one suite that drives a
# REAL agent (claude) making REAL model calls, to prove agentdev's profile
# persistence end to end:
#
#   1. create a throwaway named profile,
#   2. run a one-shot agent that writes a secret into its persistent home (memory),
#   3. assert on the HOST that both the memory file and a session transcript
#      (history) were written into the profile,
#   4. run a SECOND one-shot agent in the same profile whose prompt can only
#      succeed by reading the secret the first run persisted.
#
# This costs real model usage and needs a logged-in host. Auth is subscription:
# profile mode with auth=auto inherits the host's claude.ai login into the
# throwaway profile (the token is copied under the temp dir and removed on exit).
# Skips cleanly (exit 0) when podman, the image, or a host login is missing.
#
# Run: make test-live-agent   (or ./tests/live-agent.sh)
set -uo pipefail

REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
AD="$REPO/agentdev"
IMAGE="${IMAGE:-ghcr.io/gherlein/agentdev:latest}"
# Real model calls are slow; give each one-shot run a generous ceiling. If a run
# overruns, timeout kills the launcher and the EXIT trap force-removes the
# container by label, so a stall can never wedge podman.
RUN_TIMEOUT="${RUN_TIMEOUT:-360}"
# A random-looking token the agent cannot produce without reading the file: the
# second run's success therefore proves the first run's write actually persisted.
SECRET="CRIMSON-OTTER-7"
HOST_CREDS="$HOME/.claude/.credentials.json"

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); echo "  ok    $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL  $1"; [[ -n "${2:-}" ]] && printf '        | %s\n' "$2"; }
skip() { SKIP=$((SKIP+1)); echo "  skip  $1"; }

# --- prerequisites ---------------------------------------------------------
command -v podman >/dev/null || { echo "live-agent tests: podman not found; skipping."; exit 0; }
if ! podman image exists "$IMAGE"; then
  echo "live-agent tests: image '$IMAGE' not present (run 'make build'); skipping."; exit 0
fi
# Subscription auth: a readable host login is required. Without it, auth=auto would
# fall back to an interactive login (which would hang headless), so skip instead.
if [[ ! -r "$HOST_CREDS" ]]; then
  echo "live-agent tests: no host login at $HOST_CREDS (run 'claude' once to log in); skipping."; exit 0
fi

# --- throwaway fixtures ----------------------------------------------------
# As in live.sh we keep the real $HOME (rootless podman's image store lives there)
# and isolate only AGENTDEV_HOME, the profile roots, and the workspace. network is
# left at the default "off" (no egress *isolation*), so the agent can reach the API.
ROOT="$(mktemp -d /tmp/agentdev-live-agent.XXXX)"
# Force-remove any container this run started (profile or proxy labelled) before
# deleting the temp tree, so a crashed/detached container can never wedge podman
# or outlive the test. Each podman call is itself bounded so the trap cannot hang.
cleanup() {
  local lbl
  for lbl in agentdev.profile agentdev.proxy; do
    timeout 30 podman ps -a --filter "label=$lbl" -q 2>/dev/null \
      | xargs -r timeout 30 podman rm -f >/dev/null 2>&1
  done
  rm -rf "$ROOT"
}
trap cleanup EXIT
AH="$ROOT/agentdev-home"
WS="$ROOT/agentws"                       # plain basename -> mounts at /agentws
mkdir -p "$AH" "$WS"
cat > "$AH/config.json" <<EOF
{
  "profile": { "profiles_root": "$ROOT/profiles", "clean_root": "$ROOT/clean", "memory_root": "$ROOT/memory" },
  "template": { "source": "$REPO/templates/default" }
}
EOF

PROF="histmem"
PDIR="$ROOT/profiles/$PROF"
# A memory path we fully own, inside the profile's persistent .claude home. Using a
# fixed directory we create ourselves (rather than claude's cwd-derived project
# folder) keeps the assertion independent of claude's internal path encoding.
MEM_DIR_IN="/home/developer/.claude/agentdev-memory"
MEM_FILE_IN="$MEM_DIR_IN/secret.txt"
MEM_FILE_HOST="$PDIR/.claude/agentdev-memory/secret.txt"

# adev ARGS... - run the launcher from the workspace with the isolated
# AGENTDEV_HOME. ANTHROPIC_API_KEY is unset on purpose: with a key present,
# auth=auto would choose api-key billing instead of the subscription login under
# test. stdin is /dev/null as a backstop (--prompt already closes the agent's).
adev() { ( cd "$WS" && unset ANTHROPIC_API_KEY && AGENTDEV_HOME="$AH" \
           timeout --kill-after=15 "$RUN_TIMEOUT" "$AD" "$@" </dev/null ) 2>&1; }

# agent_run PROMPT - run one headless agent turn in the profile. The prompt is
# written to a file and handed to agentdev via --prompt (the only supported way
# to start the agent on a prompt); agentdev mounts it and runs the agent headless.
agent_run() {
  printf '%s\n' "$1" > "$ROOT/prompt.txt"
  adev --profile "$PROF" --prompt "$ROOT/prompt.txt"
}

echo "== Tier C: live agent persistence (image: $IMAGE) =="

# Seed the throwaway profile and pre-create the memory directory inside it.
adev profiles new "$PROF" >/dev/null 2>&1
mkdir -p "$PDIR/.claude/agentdev-memory"

echo "run 1: agent writes a secret into its memory, leaving a transcript:"
out1=$(agent_run "Write exactly the text ${SECRET} to the file ${MEM_FILE_IN}, with no extra characters. Then stop.")

# Hard: agentdev persisted the agent's memory write to the host profile.
if grep -q "$SECRET" "$MEM_FILE_HOST" 2>/dev/null; then
  ok "memory file persisted into the profile"
else
  bad "memory file persisted into the profile" "expected $SECRET in $MEM_FILE_HOST; run1: $out1"
fi

# Hard: a non-empty session transcript (history) landed under the profile. claude
# writes per-session .jsonl transcripts under .claude/projects/<cwd>/; we search
# broadly so the check does not depend on claude's exact path encoding.
if find "$PDIR/.claude/projects" -type f -name '*.jsonl' -size +0c 2>/dev/null | grep -q .; then
  ok "session transcript (history) persisted into the profile"
else
  bad "session transcript (history) persisted into the profile" \
      "no non-empty *.jsonl under $PDIR/.claude/projects"
fi

echo "run 2: a fresh agent must read the persisted memory to answer:"
# The answer can only be produced by reading the file the first run persisted; if
# agentdev had not kept the profile's home, the file would be absent and this fails.
ANSWER_IN="/$(basename "$WS")/answer.txt"
run2() {
  agent_run "Read the file ${MEM_FILE_IN} and write ONLY its exact contents to ${ANSWER_IN}. Output nothing else."
}
out2=$(run2)
# Soft recall: model output is non-deterministic, so allow one retry before failing.
if ! grep -q "$SECRET" "$WS/answer.txt" 2>/dev/null; then
  rm -f "$WS/answer.txt"
  out2=$(run2)
fi
if grep -q "$SECRET" "$WS/answer.txt" 2>/dev/null; then
  ok "second agent recalled the secret from persisted memory"
else
  bad "second agent recalled the secret from persisted memory" \
      "expected $SECRET in $WS/answer.txt (after one retry); run2: $out2"
fi

# Release the profile lock / reap any orphan before the temp dir is removed.
adev profiles gc >/dev/null 2>&1

echo
echo "LIVE-AGENT: $PASS passed, $FAIL failed, $SKIP skipped"
[[ $FAIL -eq 0 ]]
