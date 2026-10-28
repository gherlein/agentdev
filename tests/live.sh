#!/bin/bash
# tests/live.sh - Tier B of the testing plan (docs/testing-plan.md): a small, gated
# suite that LAUNCHES real containers to verify config options are ENFORCED at runtime
# (not merely planned). Needs podman + the built image; skips cleanly (exit 0) when
# either is missing. Net-reachability checks additionally need outbound internet.
#
# Probes run `bash -lc '<probe>'` inside the container (not an agent), so no real
# credentials or model calls are needed.
#
# Run: make test-live   (or ./tests/live.sh)
set -uo pipefail

REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
AD="$REPO/agentdev"
IMAGE="${IMAGE:-ghcr.io/gherlein/agentdev:latest}"
RUN_TIMEOUT="${RUN_TIMEOUT:-90}"

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); echo "  ok    $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL  $1"; [[ -n "${2:-}" ]] && printf '        | %s\n' "$2"; }
skip() { SKIP=$((SKIP+1)); echo "  skip  $1"; }

command -v podman >/dev/null || { echo "live tests: podman not found; skipping."; exit 0; }
if ! podman image exists "$IMAGE"; then
  echo "live tests: image '$IMAGE' not present (run 'make build'); skipping."; exit 0
fi
HAVE_NET=no
timeout 8 bash -c 'exec 3<>/dev/tcp/example.com/443' 2>/dev/null && HAVE_NET=yes

# We deliberately do NOT override $HOME: rootless podman keeps its image store there.
# The per-case config isolates the workspace and the agent home under $ROOT.
ROOT="$(mktemp -d /tmp/agentdev-live.XXXX)"
trap 'podman ps -a --filter label=agentdev.proxy -q 2>/dev/null | xargs -r podman rm -f >/dev/null 2>&1;
      podman ps -a --filter label=agentdev.home -q 2>/dev/null | xargs -r podman rm -f >/dev/null 2>&1;
      rm -rf "$ROOT"' EXIT
WS="$ROOT/ws"; mkdir -p "$WS"

# adev EXTRA_JSON ARGS... - write a config (EXTRA_JSON merged over a base that mounts
# $WS at /ws with the built image), then run the launcher with it.
adev() {
  local extra="$1"; shift
  python3 - "$ROOT/config.json" "$extra" "$IMAGE" "$WS" <<'PY'
import json, sys
path, extra, image, ws = sys.argv[1:5]
base = {"image": image, "workspace": {"source": ws, "mount": "ws"}}
def merge(a, b):
    for k, v in b.items():
        a[k] = merge(a.get(k, {}), v) if isinstance(v, dict) and isinstance(a.get(k), dict) else v
    return a
with open(path, "w") as fh:
    json.dump(merge(base, json.loads(extra)), fh)
PY
  ( timeout "$RUN_TIMEOUT" "$AD" -c "$ROOT/config.json" "$@" ) 2>&1
}

echo "== Tier B: live enforcement (image: $IMAGE) =="

echo "workspace mode:"
out=$(adev '{"workspace":{"mode":"ro"}}' -- bash -lc 'touch /ws/x 2>/dev/null && echo WRITABLE || echo READONLY')
grep -q READONLY <<<"$out" && ok "ro workspace blocks writes" || bad "ro workspace blocks writes" "$out"
out=$(adev '{}' -- bash -lc 'touch /ws/x 2>/dev/null && echo WRITABLE || echo READONLY')
grep -q WRITABLE <<<"$out" && ok "rw workspace allows writes (control)" || bad "rw workspace allows writes" "$out"

echo "ssh suppression:"
out=$(adev '{"workspace":{"ssh":false}}' -- bash -lc 'test -e /home/developer/.ssh && echo SSH || echo NOSSH')
grep -q NOSSH <<<"$out" && ok "workspace.ssh=false omits host ssh" || bad "workspace.ssh=false omits host ssh" "$out"

echo "read_write pair mount:"
out=$(adev "{\"mounts\":{\"read_write\":[{\"src\":\"$WS\",\"dest\":\"/external/out\"}]}}" -- bash -lc 'test -w /external/out && echo RW_OK || echo RW_NO')
grep -q RW_OK <<<"$out" && ok "read_write pair is writable inside" || bad "read_write pair is writable inside" "$out"

echo "agent home (mounted .claude is visible):"
AH="$ROOT/home"
adev "{\"mounts\":{\"agent_folder\":\"$AH\"}}" -- true >/dev/null 2>&1
mkdir -p "$AH/.claude/skills/demo"
printf -- '---\nname: demo\n---\nbody\n' > "$AH/.claude/skills/demo/SKILL.md"
out=$(adev "{\"mounts\":{\"agent_folder\":\"$AH\"}}" -- bash -lc 'test -f /home/developer/.claude/skills/demo/SKILL.md && echo SKILL_OK || echo SKILL_NO')
grep -q SKILL_OK <<<"$out" && ok "file in agent_folder/.claude visible inside" || bad "file in agent_folder/.claude visible inside" "$out"

echo "single-instance guard (shared agent home):"
LH="$ROOT/lockhome"
adev "{\"mounts\":{\"agent_folder\":\"$LH\"}}" -- bash -lc 'sleep 20' >/dev/null 2>&1 &
BGPID=$!
sleep 6
out=$(adev "{\"mounts\":{\"agent_folder\":\"$LH\"}}" -- bash -lc 'echo SECOND_RAN')
if grep -q SECOND_RAN <<<"$out"; then bad "second run on same home refused" "$out"
else grep -qi 'in use' <<<"$out" && ok "second run on same home refused" || bad "second run refused (wrong message)" "$out"; fi
kill "$BGPID" 2>/dev/null; wait "$BGPID" 2>/dev/null

echo "skills (read-only mount):"
SK="$ROOT/store"; mkdir -p "$SK/demo"
printf -- '---\nname: demo\n---\nbody\n' > "$SK/demo/SKILL.md"
out=$(adev "{\"skills\":{\"store\":\"$SK\",\"include\":[\"demo\"]}}" -- bash -lc '
  test -f /home/developer/.claude/skills/demo/SKILL.md || { echo NOSKILL; exit 0; }
  echo X > /home/developer/.claude/skills/demo/x 2>/dev/null && echo WRITABLE || echo READONLY')
grep -q READONLY <<<"$out" && ok "selected skill present and read-only inside" || bad "selected skill present and read-only inside" "$out"

echo "mcp (read-only mount):"
MC="$ROOT/mcpcfg"; mkdir -p "$MC"
printf '{"mcpServers":{"demo":{"command":"true"}}}' > "$MC/m.json"
out=$(adev "{\"mcp\":[\"$MC/m.json\"]}" -- bash -lc '
  test -f /home/developer/.agentdev-mcp/00-m.json || { echo NOMCP; exit 0; }
  echo X > /home/developer/.agentdev-mcp/00-m.json 2>/dev/null && echo WRITABLE || echo READONLY')
grep -q READONLY <<<"$out" && ok "selected mcp config present and read-only inside" || bad "selected mcp config present and read-only inside" "$out"

if [[ "$HAVE_NET" == yes ]]; then
  echo "network isolation:"
  out=$(adev '{"network":{"mode":"none"}}' -- bash -lc 'curl -sS -m 8 https://example.com >/dev/null 2>&1 && echo NET_OK || echo NET_BLOCKED')
  grep -q NET_BLOCKED <<<"$out" && ok "network none blocks egress" || bad "network none blocks egress" "$out"

  echo "network allowlist (proxy sidecar):"
  out=$(adev '{"network":{"mode":"allowlist","allow":["example.com","api.anthropic.com"]}}' -- bash -lc '
    curl -sS -m 12 https://example.com >/dev/null 2>&1 && echo ALLOWED_OK || echo ALLOWED_FAIL
    curl -sS -m 12 https://www.wikipedia.org >/dev/null 2>&1 && echo DENIED_REACHED || echo DENIED_BLOCKED')
  grep -q DENIED_BLOCKED <<<"$out" && ok "non-allowlisted host blocked" || bad "non-allowlisted host blocked" "$out"
  if grep -q ALLOWED_OK <<<"$out"; then ok "allowlisted host reachable"
  else skip "allowlisted host reachable (no upstream egress in this environment)"; fi
else
  skip "network isolation (host offline)"
  skip "network allowlist (host offline)"
fi

echo
echo "LIVE: $PASS passed, $FAIL failed, $SKIP skipped"
[[ $FAIL -eq 0 ]]
