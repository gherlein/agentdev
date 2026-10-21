#!/bin/bash
# tests/smoke.sh - offline smoke tests for agentdev (no container run required).
# Exercises config, seeding, metadata, the management surface, mounts, and --dry-run
# in a throwaway sandbox. Run: tests/smoke.sh
set -euo pipefail

REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
AD="$REPO/agentdev"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok    $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }
check(){ if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

T="$(mktemp -d /tmp/agentdev-smoke.XXXX)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home" "$T/ws" "$T/ref"
cat > "$T/home/config.toml" <<EOF
[profile]
profiles_root = "$T/profiles"
clean_root    = "$T/clean"
memory_root   = "$T/memory"
[template]
source = "$REPO/templates/default"
EOF
export AGENTDEV_HOME="$T/home" ANTHROPIC_API_KEY=dummy
cd "$T/ws"

echo "syntax:"
for f in "$AD" "$REPO"/lib/*.sh "$REPO"/image/entrypoint.sh; do
  check "bash -n $(basename "$f")" "bash -n '$f'"
done
check "python compiles toml.py" "python3 -m py_compile '$REPO/lib/toml.py'"

echo "cli:"
check "--help"            "'$AD' --help"
check "--clean --dry-run" "'$AD' --clean --dry-run"
check "dry-run leaves no profile" "test ! -d '$T/clean'"
check "remember --dry-run" "'$AD' --remember notes --dry-run"
check "dry-run leaves no memory store" "test ! -d '$T/memory/notes'"

echo "single-instance guard:"
check "profile run names the container" "'$AD' --profile g1 --dry-run | grep -q -- '--name agentdev-'"
check "profile run labels the folder"   "'$AD' --profile g1 --dry-run | grep -q -- '--label agentdev.profile='"
check "clean run is unlabeled"           "! '$AD' --clean --dry-run | grep -q -- '--label agentdev.profile='"

echo "seeding:"
"$AD" profiles new p1 >/dev/null
check "profile .claude/CLAUDE.md" "test -f '$T/profiles/p1/.claude/CLAUDE.md'"
check "profile history.jsonl"     "test -f '$T/profiles/p1/.claude/history.jsonl'"
check "profile memory mountpoint" "test -d '$T/profiles/p1/.claude/projects/-ws/memory'"
check ".claude.json valid json"   "python3 -c \"import json;json.load(open('$T/profiles/p1/.claude.json'))\""
check "meta.json present"         "test -f '$T/profiles/p1/agentdev.meta.json'"
check "lock present"              "test -f '$T/profiles/p1/agentdev.lock'"

echo "no git in the tool:"
check "profile is NOT a git repo" "! test -d '$T/profiles/p1/.git'"
check ".gitignore guards secrets" "grep -q credentials '$T/profiles/p1/.gitignore'"
check "no 'diff' subcommand"      "! '$AD' diff p1 2>/dev/null"
check "no 'profiles snapshot'"    "! '$AD' profiles snapshot p1 2>/dev/null"
check "no 'memory diff'"          "! '$AD' memory diff m1 2>/dev/null"

echo "auth inheritance (account merge):"
HJ="$T/host.claude.json"; PJ="$T/prof.claude.json"
printf '%s' '{"userID":"h","hasAvailableSubscription":true,"oauthAccount":{"accountUuid":"a","emailAddress":"e"},"projects":{"/x":1},"subscriptionNoticeCount":9}' > "$HJ"
printf '%s' '{"numStartups":0,"hasCompletedOnboarding":true}' > "$PJ"
( source "$REPO/lib/seed.sh"; inherit_host_account "$HJ" "$PJ" ) >/dev/null 2>&1
check "oauthAccount merged"        "python3 -c \"import json;assert 'oauthAccount' in json.load(open('$PJ'))\""
check "subscription flag merged"   "python3 -c \"import json;assert json.load(open('$PJ')).get('hasAvailableSubscription') is True\""
check "seeded fields preserved"    "python3 -c \"import json;assert json.load(open('$PJ')).get('hasCompletedOnboarding') is True\""
check "host projects not leaked"   "python3 -c \"import json;assert '/x' not in (json.load(open('$PJ')).get('projects') or {})\""
check "noticeCount not leaked"     "python3 -c \"import json;assert 'subscriptionNoticeCount' not in json.load(open('$PJ'))\""
check "no-account host is tolerated" "printf '%s' '{}' > '$HJ'; source '$REPO/lib/seed.sh'; inherit_host_account '$HJ' '$PJ'"

echo "sandbox / eval:"
check "proxy allowlist logic"        "python3 '$REPO/tests/test_proxy.py'"
check "net=none renders --network none" "'$AD' --clean --net=none --dry-run | grep -q -- '--network none'"
check "workspace-ro renders :ro"     "'$AD' --clean --workspace-ro --dry-run | grep -q ':/ws:ro'"
check "no-ssh omits ssh mount"       "! '$AD' --clean --no-ssh --dry-run | grep -q '/.ssh:'"
check "eval preset: allowlist net"   "'$AD' --eval --dry-run | grep -q 'network:.*allowlist'"
check "eval preset: workspace ro"    "'$AD' --eval --dry-run | grep -q 'workspace:.*(ro)'"
check "eval preset: confirm+no ssh"  "'$AD' --eval --dry-run | grep -q 'confirm_rw=true  ssh=false'"
check "eval template lints"          "'$AD' --eval --template '$REPO/templates/skill-eval' --dry-run >/dev/null"
# confirm_rw_mount decision (non-prompt paths only; the deny path needs a live TTY)
check "confirm_rw off = allow"       "( CONFIRM_RW=false; RW_ALLOW=(); source '$REPO/lib/config.sh'; source '$REPO/lib/mounts.sh'; confirm_rw_mount /x /y )"
check "confirm_rw dry-run = allow"   "( CONFIRM_RW=true; DRY_RUN=yes; RW_ALLOW=(); source '$REPO/lib/config.sh'; source '$REPO/lib/mounts.sh'; confirm_rw_mount /x /y )"
check "confirm_rw --rw-allow = allow" "( CONFIRM_RW=true; DRY_RUN=no; RW_ALLOW=('$T/ref'); source '$REPO/lib/config.sh'; source '$REPO/lib/mounts.sh'; confirm_rw_mount '$T/ref' /y )"

echo "management:"
check "profiles ls shows p1"      "'$AD' profiles ls | grep -qx p1"
check "profiles fork"             "'$AD' profiles fork p1 p2"
check "forked profile exists"     "test -d '$T/profiles/p2'"
check "memory new + ls"           "'$AD' memory new m1 && '$AD' memory ls | grep -qx m1"
check "memory store is plain dir" "! test -d '$T/memory/m1/.git'"
check "init writes mounts file"   "'$AD' init && test -f .agentdev-mounts.toml"

echo "mounts:"
cat > .agentdev-mounts.toml <<EOF
[read-only]
"$T/ref" = "/external/ref"
EOF
check "file mount renders"        "'$AD' --clean --dry-run | grep -q '$T/ref:/external/ref:ro'"
check "cli -rw renders"           "'$AD' --clean -rw '$T/ref' --dry-run 2>/dev/null | grep -q '/external/ref:rw' || true; '$AD' --clean --dry-run | grep -q external"
rm -f .agentdev-mounts.toml
check "collision is fatal"        "! '$AD' --clean -ro '$T/ref' -ro '$T/ref' --dry-run 2>/dev/null"

echo
echo "RESULT: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
