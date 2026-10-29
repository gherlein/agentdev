#!/bin/bash
# harness_test.sh - offline tests for factory.sh's own decisions (no podman, no models).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok    $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }

# verdict_is NAME EXPECTED REPORT_TEXT -> factory.sh audit-verdict must answer EXPECTED.
verdict_is() {
  local name="$1" expected="$2" got
  printf '%s' "$3" > "$TMP/report"
  got=$("$HERE/factory.sh" audit-verdict "$TMP/report" 2>/dev/null)
  [[ "$got" == "$expected" ]] && ok "$name -> $expected" || bad "$name -> want $expected, got '$got'"
}

echo "audit gate (a run passes only on a clean report):"
verdict_is "bare AUDIT: PASS" PASS $'AUDIT: PASS\n'
verdict_is "AUDIT: PASS with surrounding blank lines and spaces" PASS $'\n   AUDIT: PASS  \n\n'
# The first real run: the auditor listed six gaps, then ended with AUDIT: PASS.
verdict_is "gaps listed, then AUDIT: PASS" GAPS $'**R5**: pngdec.go:208 - parsing does not stop at the first error.\nAUDIT: PASS\n'
verdict_is "a preamble before AUDIT: PASS" GAPS $'I checked every rule.\nAUDIT: PASS\n'
verdict_is "no verdict at all" GAPS $'**R7**: pngdec.go:284 - missing offset prefix.\n'
verdict_is "empty report" GAPS ''
verdict_is "PASS not on its own line" GAPS $'Result: AUDIT: PASS\n'

echo
echo "HARNESS: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
