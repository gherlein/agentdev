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
. "$(dirname "${BASH_SOURCE[0]}")/cleanup.sh"
PROXIES_BEFORE="$(agentdev_proxy_ids)"
trap 'remove_own_containers "$ROOT" "$PROXIES_BEFORE"; rm -rf "$ROOT"' EXIT
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

echo "login-shell toolchain:"
# Every one-shot runs through `bash -lc`, and Debian's /etc/profile resets PATH, so the image's
# toolchains must survive a login shell or agents and harness commands start without them.
out=$(adev '{}' -- bash -lc 'for t in go node npm claude omp pi; do command -v "$t" >/dev/null || echo "MISSING:$t"; done; echo DONE')
grep -q DONE <<<"$out" && ! grep -q MISSING <<<"$out" \
  && ok "go, node, npm and every agent are on PATH in a login shell" \
  || bad "go, node, npm and every agent are on PATH in a login shell" "$(grep MISSING <<<"$out")"

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
# claude aborts its first headless run on an empty (unparseable) .claude.json, so a fresh
# home must be seeded with valid JSON.
if python3 -I -c 'import json,sys; json.load(open(sys.argv[1]))' "$AH/.claude.json" 2>/dev/null; then
  ok "fresh home's .claude.json is valid JSON"
else
  bad "fresh home's .claude.json is valid JSON" "$(stat -c '%s bytes' "$AH/.claude.json" 2>&1)"
fi
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
  test -f /home/developer/.agentdev-mcp/00.json || { echo NOMCP; exit 0; }
  echo X > /home/developer/.agentdev-mcp/00.json 2>/dev/null && echo WRITABLE || echo READONLY')
grep -q READONLY <<<"$out" && ok "selected mcp config present and read-only inside" || bad "selected mcp config present and read-only inside" "$out"

echo "host_login (per-run copy of the host login):"
# A FAKE login via CLAUDE_CONFIG_DIR: the operator's real login is never used here.
FL="$ROOT/fakelogin"; mkdir -p "$FL"
printf '{"claudeAiOauth":{"accessToken":"FAKE-HOST-LOGIN"}}\n' > "$FL/.credentials.json"
FL_SHA0="$(sha256sum "$FL/.credentials.json" | awk '{print $1}')"
CREDS_IN=/home/developer/.claude/.credentials.json
MARK="REFRESHED-$RANDOM$RANDOM"
# The in-container write mimics claude's token refresh: an in-place O_TRUNC rewrite.
# Staging goes to a TMPDIR owned by this case, so "discarded" is checked on exactly the
# run's own scratch rather than a shared /tmp grep (which root-only dirs make unfalsifiable).
HL_TMP="$ROOT/hl-tmp"; mkdir -p "$HL_TMP"
out=$(export CLAUDE_CONFIG_DIR="$FL" TMPDIR="$HL_TMP"; adev '{"host_login":true}' -- bash -lc "
  grep -q FAKE-HOST-LOGIN $CREDS_IN && echo PRESENT || echo ABSENT
  echo $MARK > $CREDS_IN 2>/dev/null && echo WROTE || echo NOWRITE")
grep -q PRESENT <<<"$out" && grep -q WROTE <<<"$out" \
  && ok "host login present and writable inside (ephemeral home)" \
  || bad "host login present and writable inside (ephemeral home)" "$out"
[[ "$(sha256sum "$FL/.credentials.json" | awk '{print $1}')" == "$FL_SHA0" ]] \
  && ok "in-container write never reaches the host login (byte-identical)" \
  || bad "in-container write never reaches the host login" "host source changed"
if [[ -z "$(ls -A "$HL_TMP")" ]]; then
  ok "staged copy discarded on exit"
else
  bad "staged copy discarded on exit" "left in TMPDIR: $(ls -A "$HL_TMP")"
fi

AH2="$ROOT/home-nocreds"
out=$(export CLAUDE_CONFIG_DIR="$FL"; adev "{\"host_login\":true,\"mounts\":{\"agent_folder\":\"$AH2\"}}" -- bash -lc "
  grep -q FAKE-HOST-LOGIN $CREDS_IN && echo PRESENT || echo ABSENT")
grep -q PRESENT <<<"$out" && ok "host login present over a persistent home" \
  || bad "host login present over a persistent home" "$out"
[[ ! -e "$AH2/.claude/.credentials.json" ]] && ok "no mount-point stub left in the persistent home" \
  || bad "no mount-point stub left in the persistent home" "$(ls -la "$AH2/.claude/" 2>&1)"

AH3="$ROOT/home-owncreds"; mkdir -p "$AH3/.claude"
printf 'HOME-OWN-CREDS\n' > "$AH3/.claude/.credentials.json"
OWN_SHA0="$(sha256sum "$AH3/.claude/.credentials.json" | awk '{print $1}')"
out=$(export CLAUDE_CONFIG_DIR="$FL"; adev "{\"host_login\":true,\"mounts\":{\"agent_folder\":\"$AH3\"}}" -- bash -lc "
  grep -q FAKE-HOST-LOGIN $CREDS_IN && echo HOSTWINS || echo HOMEWINS
  echo $MARK > $CREDS_IN 2>/dev/null || true")
grep -q HOSTWINS <<<"$out" && ok "explicit host_login wins over the home's own credentials" \
  || bad "explicit host_login wins over the home's own credentials" "$out"
[[ "$(sha256sum "$AH3/.claude/.credentials.json" | awk '{print $1}')" == "$OWN_SHA0" ]] \
  && ok "the home's own credentials are left byte-identical" \
  || bad "the home's own credentials are left byte-identical" "$(cat "$AH3/.claude/.credentials.json")"

echo "egress log (network.log):"
# A denied CONNECT is logged before any upstream connection, so this needs no internet.
AH4="$ROOT/home-egress"
adev "{\"network\":{\"mode\":\"allowlist\",\"allow\":[\"api.anthropic.com\"],\"log\":true},\"mounts\":{\"agent_folder\":\"$AH4\"}}" \
  -- bash -lc 'curl -sS -m 8 https://denied.example.org >/dev/null 2>&1; true' >/dev/null
if grep -qP '\tDENY\tCONNECT\tdenied\.example\.org:443' "$AH4/agentdev-egress.log" 2>/dev/null; then
  ok "egress log written into the agent folder (DENY recorded)"
else
  bad "egress log written into the agent folder (DENY recorded)" "$(ls -la "$AH4" 2>&1)"
fi

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

echo "test cleanup is scoped (never touches the operator's own sessions):"
# A bystander stands in for an agentdev session the operator is running right now: its home is
# outside $ROOT and its proxy existed before this test started.
BYSTANDER_HOME="$(mktemp -d /tmp/agentdev-bystander.XXXX)"
by_home=$(podman run -d --label "agentdev.home=$BYSTANDER_HOME" --entrypoint sleep "$IMAGE" 120)
by_proxy=$(podman run -d --label agentdev.proxy=bystander --entrypoint sleep "$IMAGE" 120)
BEFORE_SCOPE="$(agentdev_proxy_ids)"
own_home=$(podman run -d --label "agentdev.home=$ROOT/scoped-home" --entrypoint sleep "$IMAGE" 120)
own_proxy=$(podman run -d --label agentdev.proxy=own --entrypoint sleep "$IMAGE" 120)
remove_own_containers "$ROOT" "$BEFORE_SCOPE"
alive() { podman container exists "$1"; }
alive "$by_home" && alive "$by_proxy" && ok "operator's own agentdev containers survive test cleanup" \
  || bad "operator's own agentdev containers survive test cleanup" "bystander removed"
! alive "$own_home" && ! alive "$own_proxy" && ok "the test's own leftover containers are removed" \
  || bad "the test's own leftover containers are removed" "own container still present"
# --ignore: the test's own two are already gone, and without it podman skips the rest.
podman rm -f -t 0 --ignore "$by_home" "$by_proxy" "$own_home" "$own_proxy" >/dev/null 2>&1
alive "$by_home" || alive "$by_proxy" \
  && bad "bystander containers removed after the scoping check" "left: $by_home $by_proxy" \
  || ok "bystander containers removed after the scoping check"
rmdir "$BYSTANDER_HOME"

echo "a signal to agentdev stops its container (timeout, kill, a wrapper's Ctrl-C):"
# bash defers its traps while a foreground child runs, and podman never sees agentdev's signal,
# so without forwarding the agent keeps running and the network is never torn down.
AH5="$ROOT/home-signal"
NETS_BEFORE=$(podman network ls --format '{{.Name}}' | grep -c '^agentdev-' || true)
# adev writes the config (the dry run launches nothing); agentdev itself is then started
# directly, so $! is the launcher and not a wrapping subshell.
adev "{\"network\":{\"mode\":\"allowlist\",\"allow\":[\"api.anthropic.com\"]},\"mounts\":{\"agent_folder\":\"$AH5\"}}" \
  --dry-run >/dev/null
"$AD" -c "$ROOT/config.json" -- bash -lc 'sleep 300' >/dev/null 2>&1 &
ADEV_PID=$!
for _ in $(seq 1 60); do
  [[ -n "$(podman ps -q --filter "label=agentdev.home=$AH5")" ]] && break
  sleep 1
done
kill -TERM "$ADEV_PID"
for _ in $(seq 1 30); do kill -0 "$ADEV_PID" 2>/dev/null || break; sleep 1; done
kill -0 "$ADEV_PID" 2>/dev/null && bad "agentdev exits on SIGTERM" "still running" || ok "agentdev exits on SIGTERM"
left_ctr=$(podman ps -aq --filter "label=agentdev.home=$AH5")
NETS_AFTER=$(podman network ls --format '{{.Name}}' | grep -c '^agentdev-' || true)
[[ -z "$left_ctr" ]] && ok "SIGTERM leaves no agent container running" \
  || bad "SIGTERM leaves no agent container running" "container $left_ctr"
[[ "$NETS_AFTER" -le "$NETS_BEFORE" ]] && ok "SIGTERM tears down the allowlist networks" \
  || bad "SIGTERM tears down the allowlist networks" "$(podman network ls --format '{{.Name}}' | grep '^agentdev-')"
kill -KILL "$ADEV_PID" 2>/dev/null; podman rm -f -t 0 --ignore $left_ctr >/dev/null 2>&1

echo
echo "LIVE: $PASS passed, $FAIL failed, $SKIP skipped"
[[ $FAIL -eq 0 ]]
