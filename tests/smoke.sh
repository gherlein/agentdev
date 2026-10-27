#!/bin/bash
# smoke.sh - offline smoke tests for the agentdev launcher and config reader (Tier A).
# Everything runs via --dry-run or jsoncfg.py directly: no container, no network.
set -uo pipefail

REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
AD="$REPO/agentdev"
JC="python3 $REPO/lib/jsoncfg.py"
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL  $1"; [[ -n "${2:-}" ]] && echo "        | $2"; }
check(){ if eval "$2" >/dev/null 2>&1; then ok; else bad "$1"; fi; }           # succeeds
checkn(){ if eval "$2" >/dev/null 2>&1; then bad "$1"; else ok; fi; }          # fails

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/ws"
cfg() { cat > "$1"; }   # write a config from stdin

# A minimal valid config pointing at a real workspace.
minimal() { printf '{"image":"img:test","workspace":{"source":"%s","mount":"work"}}' "$TMP/ws"; }

# dryq FILE ... -> run agentdev --dry-run on FILE, capture to $OUT, return rc.
OUT=""
dry() { OUT="$("$AD" -c "$1" --dry-run 2>&1)"; }

echo "config resolution:"
minimal | cfg "$TMP/a.json"
check "-c explicit path"           '"$AD" -c "$TMP/a.json" --dry-run'
check "AGENTDEV_CONFIG selects"    'AGENTDEV_CONFIG="$TMP/a.json" "$AD" --dry-run'
# -c overrides $AGENTDEV_CONFIG
printf '{"workspace":{"source":"%s","mount":"ovr"}}' "$TMP/ws" | cfg "$TMP/b.json"
dry_env() { OUT="$(AGENTDEV_CONFIG="$TMP/a.json" "$AD" -c "$TMP/b.json" --dry-run 2>&1)"; }
dry_env
check "-c overrides AGENTDEV_CONFIG" 'echo "$OUT" | grep -q ":/ovr:"'
# default ./agentdev-config.json
( cd "$TMP"; cp a.json agentdev-config.json; "$AD" --dry-run >/dev/null 2>&1 ) && ok || bad "default ./agentdev-config.json"
checkn "missing -c file errors"    '"$AD" -c "$TMP/nope.json" --dry-run'
# bare, no config anywhere
( cd "$TMP"; rm -f agentdev-config.json; out="$("$AD" --dry-run 2>&1)"; echo "$out" | grep -q "no config file" ) && ok || bad "no config => error"

echo "fail-closed validation:"
printf '{"workspace":{"source":"%s"},"netwrok":{}}' "$TMP/ws" | cfg "$TMP/c.json"
checkn "typo'd top key rejected"   '"$AD" -c "$TMP/c.json" --dry-run'
printf '{"workspace":{"source":"%s","mode":"sideways"}}' "$TMP/ws" | cfg "$TMP/d.json"
checkn "bad enum rejected"         '"$AD" -c "$TMP/d.json" --dry-run'
printf '{"workspace":{"source":"/does/not/exist"}}' | cfg "$TMP/e.json"
checkn "missing workspace rejected" '"$AD" -c "$TMP/e.json" --dry-run'

echo "removed flags give migration errors:"
minimal | cfg "$TMP/a.json"
for flag in --clean --net --auth --trust -ro; do
  out="$("$AD" -c "$TMP/a.json" "$flag" x --dry-run 2>&1)"
  echo "$out" | grep -qi "was removed" && ok || bad "removed flag $flag"
done

echo "interactive vs one-shot:"
minimal | cfg "$TMP/a.json"
dry "$TMP/a.json"; echo "$OUT" | grep -q "run mode:      interactive" && ok || bad "default interactive"
printf 'do it\n' > "$TMP/task.md"
printf '{"workspace":{"source":"%s"},"one-shot":{"agent":"claude","prompt":"task.md"}}' "$TMP/ws" | cfg "$TMP/a.json"
dry "$TMP/a.json"; echo "$OUT" | grep -q "run mode:      one-shot" && ok || bad "one-shot block"
# --prompt forces one-shot on an otherwise-interactive config
minimal | cfg "$TMP/a.json"
OUT="$("$AD" -c "$TMP/a.json" --prompt "$TMP/task.md" --dry-run 2>&1)"
echo "$OUT" | grep -q "run mode:      one-shot" && ok || bad "--prompt forces one-shot"

echo "jsoncfg verbs:"
printf '{"image":"x","workspace":{"source":".","files":[{"source":"a","name":".env"}]},"mounts":{"read_only":[{"src":"s","dest":"/d"}]},"one-shot":{"agent":"claude"}}' | cfg "$TMP/j.json"
check "get scalar"   '[ "$($JC get "$TMP/j.json" image)" = "x" ]'
check "has one-shot"  '$JC has "$TMP/j.json" one-shot'
checkn "has missing"  '$JC has "$TMP/j.json" network'
check "rows pairs"    '[ "$($JC rows "$TMP/j.json" mounts.read_only src dest)" = "$(printf "s\t/d")" ]'
check "rows files"    '[ "$($JC rows "$TMP/j.json" workspace.files source name)" = "$(printf "a\t.env")" ]'
check "validate ok"   '$JC validate "$TMP/j.json"'
printf '{"bogus":1}' | cfg "$TMP/k.json"
checkn "validate bad" '$JC validate "$TMP/k.json"'

echo
echo "RESULT: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
