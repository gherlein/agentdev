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
echo "coder backend (CODER_BACKEND=sglang goes straight to SGLang):"
printf 'AUDIT: PASS\n' > "$TMP/report"
CODER_BACKEND=bogus "$HERE/factory.sh" audit-verdict "$TMP/report" >/dev/null 2>&1
[[ $? -eq 2 ]] && ok "an unknown CODER_BACKEND is rejected" || bad "an unknown CODER_BACKEND is accepted"
key_in_home=$(sed -n 's/^SGLANG_KEY_IN_HOME=//p' "$HERE/factory.sh")
grep -qF "apiKey: \"!cat /home/developer/$key_in_home\"" "$HERE/omp-seed/qwen-sglang/.omp/agent/models.yml" \
  && ok "the sglang seed reads the key from where factory.sh puts it ($key_in_home)" \
  || bad "the sglang seed's apiKey does not read /home/developer/$key_in_home"
allow=$(python3 -I -c 'import json,sys; print(" ".join(json.load(open(sys.argv[1]))["network"]["allow"]))' "$HERE/profiles/coder-sglang.json")
[[ "$allow" == "dgx1.herlein.me:30001" ]] && ok "coder-sglang egress is the SGLang proxy only" || bad "coder-sglang egress is '$allow'"
grep -q 'litellm' "$HERE/omp-seed/qwen-sglang/.omp/agent/config.yml" \
  && bad "the sglang seed still routes a role through litellm" || ok "every sglang seed role uses the sglang provider"

# A whole pipeline against a fake agentdev: it writes the reasoner documents, passes verify and
# the audit, and notes whether the coder's home held the key while the coder step ran.
cat > "$TMP/fake-agentdev" <<'EOF'
#!/bin/bash
dir=$(dirname "$2"); profile=$(basename "$2" .json)
case "$profile" in
  reasoner) printf 'x\n' > "$dir/work/REQUIREMENTS.md"; printf 'x\n' > "$dir/work/DESIGN.md" ;;
  coder*) [[ -f "$dir/homes/coder/.omp/agent/qwen38-api-key" ]] && echo "$profile key" >> "$FAKE_LOG" || echo "$profile nokey" >> "$FAKE_LOG" ;;
  auditor) echo "AUDIT: PASS" ;;
esac
exit 0
EOF
chmod +x "$TMP/fake-agentdev"
printf 'fake-key\n' > "$TMP/key"

# pipeline_with BACKEND -> one fake run; prints its run dir, which the caller deletes.
pipeline_with() {
  local label="harness-$1-$$"
  FAKE_LOG="$TMP/log-$1" AGENTDEV="$TMP/fake-agentdev" QWEN38_KEY_FILE="$TMP/key" CODER_BACKEND="$1" \
    "$HERE/factory.sh" run "$label" >"$TMP/run-$1.out" 2>&1
  ls -d "$HERE"/runs/*-"$label"
}
for backend in sglang litellm; do
  run_dir=$(pipeline_with "$backend")
  case "$backend" in sglang) want="coder-sglang key" ;; litellm) want="coder nokey" ;; esac
  [[ "$(sort -u "$TMP/log-$backend")" == "$want" ]] \
    && ok "$backend: the coder step saw '$want'" || bad "$backend: coder step saw '$(sort -u "$TMP/log-$backend" | tr '\n' ' ')', want '$want'"
  left=$(find "$run_dir" -name qwen38-api-key | wc -l)
  [[ $left -eq 0 ]] && ok "$backend: no key file is left in the run" || bad "$backend: $left key file(s) left in the run"
  grep -q "\"coder_backend\": \"$backend\"" "$run_dir/meta.json" \
    && ok "$backend: meta.json records the backend" || bad "$backend: meta.json lacks coder_backend $backend"
  find "$run_dir" -delete
done

echo
echo "HARNESS: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
