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
# Run each probe with pipefail OFF: a check is `producer | grep -q PAT`, where grep
# exits on its first match and closes the pipe, so the producer can take SIGPIPE
# before it finishes writing. Under the script's `set -o pipefail` that SIGPIPE
# would fail the pipeline even though grep matched (flaky for early-line matches).
check(){ if ( set +o pipefail; eval "$2" ) >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }
# dryq PATTERN [ARGS...] - true if a --dry-run's output matches PATTERN. Captures
# the output first, so an early grep -q match can't SIGPIPE the launcher.
dryq() { local pat="$1"; shift; local out; out="$("$AD" "$@" --dry-run 2>/dev/null)"; grep -q -- "$pat" <<<"$out"; }

T="$(mktemp -d /tmp/agentdev-smoke.XXXX)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home" "$T/ws" "$T/ref"
cat > "$T/home/config.json" <<EOF
{
  "profile": { "profiles_root": "$T/profiles", "clean_root": "$T/clean", "memory_root": "$T/memory" },
  "template": { "source": "$REPO/templates/default" }
}
EOF
export AGENTDEV_HOME="$T/home" ANTHROPIC_API_KEY=dummy
cd "$T/ws"

echo "syntax:"
for f in "$AD" "$REPO"/lib/*.sh "$REPO"/image/entrypoint.sh; do
  check "bash -n $(basename "$f")" "bash -n '$f'"
done
check "python compiles jsoncfg.py" "python3 -m py_compile '$REPO/lib/jsoncfg.py'"

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
check "init writes config file"   "'$AD' init && test -f agentdev-config.json && python3 -c \"import json;json.load(open('agentdev-config.json'))\""
check "init refuses overwrite"    "! '$AD' init 2>/dev/null"
rm -f agentdev-config.json

echo "mounts:"
check "cli -ro renders"           "dryq '$T/ref:/external/ref:ro' --clean -ro '$T/ref'"
check "cli -rw renders"           "dryq '$T/ref:/external/ref:rw' --clean -rw '$T/ref'"
cat > agentdev-config.json <<EOF
{ "mounts": { "read_only": { "$T/ref": "/external/cfgref" } } }
EOF
check "config mount renders"      "dryq '$T/ref:/external/cfgref:ro' --clean"
rm -f agentdev-config.json
check "collision is fatal"        "! '$AD' --clean -ro '$T/ref' -ro '$T/ref' --dry-run 2>/dev/null"

echo "prompt file (--prompt):"
printf 'do the thing with "quotes" and $vars and `ticks`\n' > "$T/ws/prompt.txt"
check "--prompt mounts the file ro" "dryq ':/home/developer/.agentdev-prompt:ro' --clean --prompt '$T/ws/prompt.txt'"
check "--prompt reads it via cat"   "dryq 'cat.*agentdev-prompt' --clean --prompt '$T/ws/prompt.txt'"
check "--prompt shown in plan"      "dryq 'prompt file:' --clean --prompt '$T/ws/prompt.txt'"
check "--prompt relative path ok"   "dryq ':/home/developer/.agentdev-prompt:ro' --clean --prompt prompt.txt"
check "--prompt + command is fatal" "! '$AD' --clean --prompt '$T/ws/prompt.txt' -- bash --dry-run 2>/dev/null"
check "missing --prompt is fatal"   "! '$AD' --clean --prompt '$T/no-such.txt' --dry-run 2>/dev/null"
rm -f "$T/ws/prompt.txt"

echo "json config:"
mkdir -p "$T/ws/sub"
cat > agentdev-config.json <<EOF
{
  "profile": { "default_mode": "profile", "name": "jp", "profiles_root": "$T/profiles",
               "clean_root": "$T/clean", "memory_root": "$T/memory" },
  "template": { "source": "$REPO/templates/default" },
  "workspace": { "trust": "workspace-only", "workdir": "sub" },
  "network": { "mode": "none" },
  "mounts": { "read_only": { "$T/ref": "/external/jref" } }
}
EOF
check "default ./agentdev-config.json read" "dryq 'profile:.*/profiles/jp'"
check "config drives mode"         "dryq 'mode:.*profile'"
check "config drives trust"        "dryq 'trust:.*workspace-only'"
check "config drives network"      "dryq 'network:.*none'"
check "entry folder from config"   "dryq 'entry folder:  /ws/sub'"
check "entry folder sets -w"       "dryq '[-]w /ws/sub'"
check "entry folder sets env"      "dryq 'AGENTDEV_WORKDIR=/ws/sub'"
check "json mount renders"         "dryq '$T/ref:/external/jref:ro'"
check "CLI mode wins over config"  "dryq 'mode:.*clean' --clean"
check "CLI --workdir wins"         "dryq 'entry folder:  /ws$' --workdir ."
check "-c explicit path"           "dryq '/profiles/jp' -c '$T/ws/agentdev-config.json'"
check "bad entry folder is fatal"  "! '$AD' --workdir nope --dry-run 2>/dev/null"
check "missing -c file is fatal"   "! '$AD' -c '$T/no-such.json' --dry-run 2>/dev/null"
check "invalid json is fatal"      "printf '{bad' > bad.json; ! '$AD' -c bad.json --dry-run 2>/dev/null"
rm -f agentdev-config.json bad.json
# Project config overrides the user config (~/.agentdev/config.json) for a key.
cat > "$T/home/config.json" <<EOF
{ "profile": { "profiles_root": "$T/profiles", "clean_root": "$T/clean", "memory_root": "$T/memory" },
  "template": { "source": "$REPO/templates/default" },
  "workspace": { "trust": "skip-permissions" } }
EOF
check "user config applies"           "dryq 'trust:.*skip-permissions' --clean"
cat > agentdev-config.json <<EOF
{ "workspace": { "trust": "prompt" } }
EOF
check "project config overrides user" "dryq 'trust:.*prompt' --clean"
rm -f agentdev-config.json

echo "bare invocation (no flags):"
# A bare `agentdev` must launch straight from a resolvable config (the documented
# folder-per-context workflow) and only fall back to usage when there is no config
# at all. Exercised offline with a podman stub that records the launch and a fresh
# AGENTDEV_HOME so the host's real ~/.agentdev never leaks in.
BARE="$T/bare"; mkdir -p "$BARE/withconfig" "$BARE/noconfig" "$BARE/home" "$BARE/bin"
cat > "$BARE/bin/podman" <<'STUB'
#!/bin/bash
echo "PODMAN-STUB-RAN"
STUB
chmod +x "$BARE/bin/podman"
cat > "$BARE/withconfig/agentdev-config.json" <<EOF
{
  "profile": { "default_mode": "clean", "profiles_root": "$T/profiles",
               "clean_root": "$BARE/clean", "memory_root": "$T/memory" },
  "template": { "source": "$REPO/templates/default" },
  "sandbox": { "ssh": false }
}
EOF
BARE_ENV="AGENTDEV_HOME='$BARE/home' PATH='$BARE/bin:$PATH'"
# With a project config present, bare launch reaches the (stubbed) container run...
check "bare + config launches"       "cd '$BARE/withconfig' && eval $BARE_ENV '$AD' 2>/dev/null | grep -q PODMAN-STUB-RAN"
check "bare + config shows no usage" "cd '$BARE/withconfig' && ! eval $BARE_ENV '$AD' 2>&1 | grep -q 'Usage:'"
# ...but with no config anywhere it must still refuse and print usage, exit non-zero.
check "bare + no config = usage"     "cd '$BARE/noconfig' && eval $BARE_ENV '$AD' 2>&1 | grep -q 'Usage:'"
check "bare + no config exits 1"     "cd '$BARE/noconfig' && ! ( eval $BARE_ENV '$AD' >/dev/null 2>&1 )"
check "bare + no config no launch"   "cd '$BARE/noconfig' && ! eval $BARE_ENV '$AD' 2>/dev/null | grep -q PODMAN-STUB-RAN"
# -h/--help always prints usage and exits 0 regardless of config.
check "--help exits 0 with config"   "cd '$BARE/withconfig' && eval $BARE_ENV '$AD' --help | grep -q 'Usage:'"
cd "$T/ws"

echo
echo "RESULT: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
