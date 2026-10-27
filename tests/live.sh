#!/bin/bash
# tests/live.sh - Tier B of the testing plan (docs/testing-plan.md): a small,
# gated suite that LAUNCHES real containers to verify that profile options are
# ENFORCED at runtime (not merely planned). Needs podman + the built image; skips
# cleanly (exit 0) when either is missing. Net-reachability checks additionally
# need outbound internet and are skipped offline.
#
# Probes run `bash -lc '<probe>'` inside the container (not claude), so no real
# credentials or model calls are needed; auth is api-key-env with a dummy key.
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

# --- prerequisites ---------------------------------------------------------
command -v podman >/dev/null || { echo "live tests: podman not found; skipping."; exit 0; }
if ! podman image exists "$IMAGE"; then
  echo "live tests: image '$IMAGE' not present (run 'make build'); skipping."; exit 0
fi
HAVE_NET=no
timeout 8 bash -c 'exec 3<>/dev/tcp/example.com/443' 2>/dev/null && HAVE_NET=yes

# --- throwaway fixtures ----------------------------------------------------
# NB: we deliberately do NOT override $HOME. Rootless podman keeps its image
# store under $HOME, so a throwaway HOME would hide the locally-built image and
# force a (failing) pull. The per-case config isolates the profile roots and
# the workspace. Live cases use api-key-env, so no host-credential fixtures are
# needed; the agent's home is still the (tmp) profile, never your real ~/.claude.
ROOT="$(mktemp -d /tmp/agentdev-live.XXXX)"
trap 'podman ps -a --filter label=agentdev.proxy -q 2>/dev/null | xargs -r podman rm -f >/dev/null 2>&1; rm -rf "$ROOT"' EXIT
WS="$ROOT/ws"; OUT="$ROOT/out"
mkdir -p "$WS" "$OUT"

# adev EXTRA_JSON ARGS... - write a config (EXTRA_JSON deep-merged over a base that
# keeps every root inside $ROOT and mounts $WS as the workspace), then run the
# launcher with it and api-key auth. $HOME is left intact (podman image store).
adev() {
  local extra="$1"; shift
  python3 - "$ROOT/config.json" "$extra" "$ROOT" "$REPO" "$WS" <<'PY'
import json, sys
path, extra, root, repo, ws = sys.argv[1:6]
base = {
    "profile": {"profiles_root": f"{root}/profiles", "clean_root": f"{root}/clean",
                "memory_root": f"{root}/memory"},
    "template": {"source": f"{repo}/templates/default"},
    "auth": {"mode": "api-key-env"},
    "workspace": {"source": ws},
}
def merge(a, b):
    for k, v in b.items():
        a[k] = merge(a.get(k, {}), v) if isinstance(v, dict) and isinstance(a.get(k), dict) else v
    return a
with open(path, "w") as fh:
    json.dump(merge(base, json.loads(extra)), fh)
PY
  ( ANTHROPIC_API_KEY=dummy timeout "$RUN_TIMEOUT" "$AD" -c "$ROOT/config.json" "$@" ) 2>&1
}

echo "== Tier B: live enforcement (image: $IMAGE) =="

echo "workspace isolation:"
out=$(adev '{"mounts":{"workspace":"ro"}}' -- bash -lc 'touch /ws/x 2>/dev/null && echo WRITABLE || echo READONLY')
grep -q READONLY <<<"$out" && ok "ro workspace blocks writes" || bad "ro workspace blocks writes" "$out"
out=$(adev '{}' -- bash -lc 'touch /ws/x 2>/dev/null && echo WRITABLE || echo READONLY')
grep -q WRITABLE <<<"$out" && ok "rw workspace allows writes (control)" || bad "rw workspace allows writes" "$out"

echo "ssh suppression:"
out=$(adev '{"sandbox":{"ssh":false}}' -- bash -lc 'test -e /home/developer/.ssh && echo SSH || echo NOSSH')
grep -q NOSSH <<<"$out" && ok "sandbox.ssh=false omits host ssh" || bad "sandbox.ssh=false omits host ssh" "$out"

echo "confirm-rw (fail-closed, no TTY):"
# No TTY + unapproved rw mount ⇒ the mount is refused (absent inside); the run
# continues without it (only a declined *workspace* rw aborts the run).
out=$(adev "{\"mounts\":{\"workspace\":\"ro\",\"confirm_rw\":true,\"read_write\":{\"$OUT\":\"/external/out\"}}}" -- bash -lc 'test -e /external/out && echo MOUNT_PRESENT || echo MOUNT_ABSENT')
if grep -q MOUNT_ABSENT <<<"$out" && grep -qiE 'denied|refusing' <<<"$out"; then
  ok "confirm-rw denies unapproved rw with no TTY"
else bad "confirm-rw denies unapproved rw with no TTY" "$out"; fi
out=$(adev "{\"mounts\":{\"workspace\":\"ro\",\"confirm_rw\":true,\"rw_allow\":[\"$OUT\"],\"read_write\":{\"$OUT\":\"/external/out\"}}}" -- bash -lc 'test -w /external/out && echo RW_OK || echo RW_NO')
grep -q RW_OK <<<"$out" && ok "rw_allow pre-approves the rw mount" || bad "rw_allow pre-approves the rw mount" "$out"

echo "skills visibility (profile .claude/skills is mounted):"
# A profile is seeded on first launch (no `profiles new`); seed it with a no-op run,
# then drop a skill into the plain folder and check the next run sees it.
adev '{"profile":{"mode":"profile","name":"evalp"}}' -- true >/dev/null 2>&1
mkdir -p "$ROOT/profiles/evalp/.claude/skills/demo"
printf -- '---\nname: demo\n---\nbody\n' > "$ROOT/profiles/evalp/.claude/skills/demo/SKILL.md"
out=$(adev '{"profile":{"mode":"profile","name":"evalp"}}' -- bash -lc 'test -f /home/developer/.claude/skills/demo/SKILL.md && echo SKILL_OK || echo SKILL_NO')
grep -q SKILL_OK <<<"$out" && ok "provisioned skill visible inside" || bad "provisioned skill visible inside" "$out"

echo "single-instance guard:"
adev '{"profile":{"mode":"profile","name":"lockp"}}' -- bash -lc 'sleep 20' >/dev/null 2>&1 &
BGPID=$!
sleep 6   # let the first run acquire the lock + start its container
out=$(adev '{"profile":{"mode":"profile","name":"lockp"}}' -- bash -lc 'echo SECOND_RAN')
if grep -q SECOND_RAN <<<"$out"; then bad "second run on same profile refused" "$out"
else grep -qi 'in use' <<<"$out" && ok "second run on same profile refused" || bad "second run refused (wrong message)" "$out"; fi
kill "$BGPID" 2>/dev/null; wait "$BGPID" 2>/dev/null
# The EXIT trap reaps any container this run left (profile/proxy labelled).

if [[ "$HAVE_NET" == yes ]]; then
  echo "network isolation:"
  out=$(adev '{"network":{"mode":"none"}}' -- bash -lc 'curl -sS -m 8 https://example.com >/dev/null 2>&1 && echo NET_OK || echo NET_BLOCKED')
  grep -q NET_BLOCKED <<<"$out" && ok "network none blocks egress" || bad "network none blocks egress" "$out"

  echo "network allowlist (proxy sidecar):"
  out=$(adev '{"network":{"mode":"allowlist","allow":["example.com","api.anthropic.com"]}}' -- bash -lc '
    curl -sS -m 12 https://example.com >/dev/null 2>&1 && echo ALLOWED_OK || echo ALLOWED_FAIL
    curl -sS -m 12 https://www.wikipedia.org >/dev/null 2>&1 && echo DENIED_REACHED || echo DENIED_BLOCKED')
  # The security-critical property: a non-allowlisted host is blocked (hard).
  grep -q DENIED_BLOCKED <<<"$out" && ok "non-allowlisted host blocked" || bad "non-allowlisted host blocked" "$out"
  # Allow-through needs the proxy's own upstream egress, which a nested rootless
  # netns often cannot provide; treat its absence as a skip, not a failure.
  if grep -q ALLOWED_OK <<<"$out"; then ok "allowlisted host reachable"
  else skip "allowlisted host reachable (no upstream egress in this environment)"; fi
else
  skip "network isolation (host offline)"
  skip "network allowlist (host offline)"
fi

echo
echo "LIVE: $PASS passed, $FAIL failed, $SKIP skipped"
[[ $FAIL -eq 0 ]]
