#!/bin/bash
# tests/smoke.sh - offline smoke tests for agentdev (no container run required).
# Exercises config validation, seeding, metadata, the management surface, mounts,
# model selection, and --dry-run in a throwaway sandbox. Run: tests/smoke.sh
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
# drynot PATTERN [ARGS...] - true if a --dry-run SUCCEEDS and its output lacks PATTERN.
drynot() { local pat="$1"; shift; local out; out="$("$AD" "$@" --dry-run 2>/dev/null)" || return 1; ! grep -q -- "$pat" <<<"$out"; }
# dryerr PATTERN [ARGS...] - true if a --dry-run FAILS and its stderr matches PATTERN.
dryerr() { local pat="$1"; shift; local out; if out="$("$AD" "$@" --dry-run 2>&1)"; then return 1; fi; grep -q -- "$pat" <<<"$out"; }

T="$(mktemp -d /tmp/agentdev-smoke.XXXX)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/ws" "$T/ref" "$T/cfgdir/rel"
export ANTHROPIC_API_KEY=dummy
cd "$T/ws"

# cfg [FILE] JSON - write FILE (default ./agentdev-config.json): the JSON object
# deep-merged over a base that keeps every root and the template inside $T.
cfg() {
  local file="agentdev-config.json"
  [[ $# -eq 2 ]] && { file="$1"; shift; }
  python3 - "$file" "$1" "$T" "$REPO" <<'PY'
import json, sys
path, extra, tmp, repo = sys.argv[1:5]
base = {
    "profile": {"profiles_root": f"{tmp}/profiles", "clean_root": f"{tmp}/clean",
                "memory_root": f"{tmp}/memory"},
    "template": {"source": f"{repo}/templates/default"},
}
def merge(a, b):
    for k, v in b.items():
        a[k] = merge(a.get(k, {}), v) if isinstance(v, dict) and isinstance(a.get(k), dict) else v
    return a
with open(path, "w") as fh:
    json.dump(merge(base, json.loads(extra)), fh)
PY
}

# seed_into DIR - seed a profile at DIR from the current ./agentdev-config.json by
# sourcing the libraries directly (there is no `profiles new` subcommand; a profile
# is seeded on first launch). IMAGE is pointed at an absent image so write_lock does
# not launch a container — keeps the offline suite offline.
seed_into() {
  ( set -e
    SELFDIR="$REPO"; LIBDIR="$REPO/lib"
    source "$REPO/lib/config.sh"; source "$REPO/lib/seed.sh"
    source "$REPO/lib/meta.sh";   source "$REPO/lib/memory.sh"
    JSON_CONFIG="$PWD/agentdev-config.json"; JSON_CONFIG_EXPLICIT=yes
    load_config
    IMAGE="localhost/agentdev-offline-test:none"
    MODE=clean; RUN_ID=seed-test; MEMORY_STORE=""
    PROFILE="$1"; compute_enc "$DIR_NAME"
    seed_profile; write_meta; write_lock )
}

echo "syntax:"
for f in "$AD" "$REPO"/lib/*.sh "$REPO"/image/entrypoint.sh; do
  check "bash -n $(basename "$f")" "bash -n '$f'"
done
check "python compiles jsoncfg.py"   "python3 -m py_compile '$REPO/lib/jsoncfg.py'"
check "python compiles allowcheck.py" "python3 -m py_compile '$REPO/lib/allowcheck.py'"

echo "cli:"
cfg '{}'
check "--help"                      "'$AD' --help"
check "--dry-run"                   "'$AD' --dry-run"
check "dry-run leaves no profile"   "test ! -d '$T/clean'"
cfg '{"profile":{"mode":"remember","memory_store":"notes"}}'
check "remember --dry-run"          "'$AD' --dry-run"
check "dry-run leaves no memory store" "test ! -d '$T/memory/notes'"
check "removed flag names its key"  "dryerr 'set profile.mode' --clean"
check "removed --net names its key" "dryerr 'set network.mode' --net=none"
check "removed -ro names its key"   "dryerr 'mounts.read_only' -ro '$T/ref'"
check "removed --reseed explains re-seed" "dryerr 'delete the profile folder' --reseed"
check "unknown flag is fatal"       "dryerr 'unknown argument' --bogus"

echo "strict config:"
cfg '{"netwrok":{"mode":"none"}}'
check "unknown key is fatal"        "dryerr 'netwrok: unknown key'"
cfg '{"profile":{"default_mode":"clean"}}'
check "retired key names its replacement" "dryerr 'renamed to profile.mode'"
cfg '{"workspace":{"isolation":"mount"}}'
check "removed key is fatal"        "dryerr 'workspace.isolation: removed'"
cfg '{"profile":{"keep":"yes"}}'
check "string boolean is fatal"     "dryerr 'profile.keep: must be true or false'"
cfg '{"workspace":{"trust":"bogus"}}'
check "bad trust value is fatal"    "dryerr 'workspace.trust: must be one of'"
cfg '{"agent":{"name":"opencode"}}'
check "unsupported agent is fatal"  "dryerr 'agent.name: must be one of claude'"
cfg '{"model":{"base_url":"not a url"}}'
check "bad base_url is fatal"       "dryerr 'model.base_url: must be an http'"
cfg '{"model":{"pass_env":["BAD-NAME"]}}'
check "bad env name is fatal"       "dryerr 'not a valid environment variable name'"
cfg '{"//":"a comment","mounts":{"//":"also a comment"}}'
check "// keys are comments"        "'$AD' --dry-run"

echo "single-instance guard:"
cfg '{"profile":{"mode":"profile","name":"g1"}}'
check "profile run names the container" "dryq '--name agentdev-'"
check "profile run labels the folder"   "dryq '--label agentdev.profile='"
check "profile mode needs a name"       "cfg '{\"profile\":{\"mode\":\"profile\"}}'; dryerr 'needs profile.name'"
cfg '{}'
check "clean run is unlabeled"          "drynot '--label agentdev.profile='"

echo "seeding (via the seeder; a profile is seeded on first launch):"
cfg '{}'
P1="$T/profiles/p1"
check "seeder builds the profile"  "seed_into '$P1'"
check "profile .claude/CLAUDE.md"  "test -f '$P1/.claude/CLAUDE.md'"
check "profile history.jsonl"      "test -f '$P1/.claude/history.jsonl'"
check "profile memory mountpoint"  "test -d '$P1/.claude/projects/-ws/memory'"
check ".claude.json valid json"    "python3 -c \"import json;json.load(open('$P1/.claude.json'))\""
check "meta.json present"          "test -f '$P1/agentdev.meta.json'"
check "lock present"               "test -f '$P1/agentdev.lock'"

echo "no git / no management surface in the tool:"
check "profile is NOT a git repo"  "! test -d '$P1/.git'"
check ".gitignore guards secrets"  "grep -q credentials '$P1/.gitignore'"
check "no 'profiles' subcommand"   "dryerr 'unknown argument' profiles ls"
check "no 'memory' subcommand"     "dryerr 'unknown argument' memory ls"
check "no 'report' subcommand"     "dryerr 'unknown argument' report p1"
check "no 'doctor' subcommand"     "dryerr 'unknown argument' doctor"
check "no 'init' subcommand"       "dryerr 'unknown argument' init"
check "no 'build' subcommand"      "dryerr 'unknown argument' build"

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
check "api key never printed"      "cfg '{}'; drynot 'ANTHROPIC_API_KEY=dummy'"
check "api key forwarded by name"  "dryq ' -e ANTHROPIC_API_KEY '"

echo "sandbox:"
check "proxy allowlist logic"        "python3 '$REPO/tests/test_proxy.py'"
check "network none renders --network none" "cfg '{\"network\":{\"mode\":\"none\"}}'; dryq '--network none'"
check "workspace ro renders :ro"     "cfg '{\"mounts\":{\"workspace\":\"ro\"}}'; dryq ':/ws:ro'"
check "ssh=false omits ssh mount"    "cfg '{\"sandbox\":{\"ssh\":false}}'; drynot '/.ssh:'"
check "usb=false omits usb device"   "cfg '{\"sandbox\":{\"usb\":false}}'; drynot '/dev/bus/usb'"
check "host_ca=false omits CA env"   "cfg '{\"sandbox\":{\"host_ca\":false}}'; drynot 'REFRESH_CA_CERTS'"
# Controls for the two checks above: the defaults do pass these through, where the
# host has them, so the omissions are caused by the keys and not by the host.
if [[ -d /dev/bus/usb ]]; then
  check "usb default passes the device" "cfg '{}'; dryq '--device /dev/bus/usb'"
fi
if [[ -n "$(find /usr/local/share/ca-certificates /etc/pki/ca-trust/source/anchors -maxdepth 1 -type f 2>/dev/null | head -1)" ]]; then
  check "host_ca default mounts anchors" "cfg '{}'; dryq 'REFRESH_CA_CERTS'"
fi
check "skill-eval template lints"    "cfg '{\"template\":{\"source\":\"$REPO/templates/skill-eval\"}}'; '$AD' --dry-run"
check "missing device is fatal"      "cfg '{\"mounts\":{\"devices\":[\"/dev/agentdev-no-such\"]}}'; dryerr 'not a character or block device'"
check "device renders --device"      "cfg '{\"mounts\":{\"devices\":[\"/dev/null\"]}}'; dryq '--device /dev/null'"
# confirm_rw_mount decision (non-prompt paths only; the deny path needs a live TTY)
check "confirm_rw off = allow"       "( CONFIRM_RW=false; RW_ALLOW=(); source '$REPO/lib/config.sh'; source '$REPO/lib/mounts.sh'; confirm_rw_mount /x /y )"
check "confirm_rw dry-run = allow"   "( CONFIRM_RW=true; DRY_RUN=yes; RW_ALLOW=(); source '$REPO/lib/config.sh'; source '$REPO/lib/mounts.sh'; confirm_rw_mount /x /y )"
check "confirm_rw rw_allow = allow"  "( CONFIRM_RW=true; DRY_RUN=no; RW_ALLOW=('$T/ref'); source '$REPO/lib/config.sh'; source '$REPO/lib/mounts.sh'; confirm_rw_mount '$T/ref' /y )"

echo "network allowlist and model endpoint:"
cfg '{"network":{"mode":"allowlist","allow":[]}}'
check "empty allowlist is fatal"     "dryerr 'network.allow is empty'"
cfg '{"network":{"mode":"allowlist","allow":["example.com"]}}'
check "endpoint not allowed is fatal" "dryerr 'does not allow the model endpoint api.anthropic.com:443'"
cfg '{"network":{"mode":"allowlist","allow":["api.anthropic.com"]}}'
check "endpoint allowed launches"    "dryq 'network:       allowlist'"
cfg '{"network":{"mode":"allowlist","allow":["*.anthropic.com"]}}'
check "wildcard allows endpoint"     "dryq 'endpoint:      api.anthropic.com:443'"
cfg '{"network":{"mode":"allowlist","allow":["api.anthropic.com:8443"]}}'
check "wrong port denies endpoint"   "dryerr 'does not allow the model endpoint'"

echo "model:"
cfg '{"model":{"id":"claude-opus-5-5"}}'
check "model id sets ANTHROPIC_MODEL" "dryq 'ANTHROPIC_MODEL=claude-opus-5-5'"
check "model shown in plan"          "dryq 'model:         claude-opus-5-5'"
cfg '{}'
check "no model id sets nothing"     "drynot 'ANTHROPIC_MODEL'"
cfg '{"model":{"base_url":"https://gw.example.com:8443/v1"}}'
check "base_url sets ANTHROPIC_BASE_URL" "dryq 'ANTHROPIC_BASE_URL=https://gw.example.com:8443/v1'"
check "base_url drives endpoint"     "dryq 'endpoint:      gw.example.com:8443'"
cfg '{"model":{"base_url":"http://localhost:4000"},"network":{"mode":"allowlist","allow":["localhost:4000"]}}'
check "http base_url default port and interlock" "dryq 'endpoint:      localhost:4000'"
cfg '{"model":{"provider":"bedrock","pass_env":["AWS_REGION","AWS_PROFILE"]}}'
check "bedrock sets the provider flag" "AWS_REGION=us-west-2 AWS_PROFILE=x dryq 'CLAUDE_CODE_USE_BEDROCK=1'"
check "bedrock endpoint from region"   "AWS_REGION=us-west-2 AWS_PROFILE=x dryq 'endpoint:      bedrock-runtime.us-west-2.amazonaws.com:443'"
check "pass_env forwards by name only" "AWS_REGION=us-west-2 AWS_PROFILE=secretprofile drynot 'secretprofile' && AWS_REGION=us-west-2 AWS_PROFILE=secretprofile dryq ' -e AWS_PROFILE '"
check "pass_env unset on host is fatal" "AWS_REGION=us-west-2 dryerr 'AWS_PROFILE is not set'"
check "bedrock auth is provider-env"   "AWS_REGION=us-west-2 AWS_PROFILE=x dryq 'auth: auto -> provider-env'"
cfg '{"model":{"provider":"bedrock"}}'
check "bedrock without region is fatal" "dryerr 'needs AWS_REGION'"
cfg '{"model":{"provider":"bedrock","pass_env":["AWS_REGION"]},"auth":{"mode":"api-key-env"}}'
check "bedrock with explicit auth is fatal" "AWS_REGION=us-west-2 dryerr 'authenticates via model.pass_env'"
cfg '{"model":{"provider":"vertex","pass_env":["CLOUD_ML_REGION","ANTHROPIC_VERTEX_PROJECT_ID"]}}'
check "vertex regional endpoint"     "CLOUD_ML_REGION=us-east5 ANTHROPIC_VERTEX_PROJECT_ID=p dryq 'endpoint:      us-east5-aiplatform.googleapis.com:443'"
check "vertex global endpoint"       "CLOUD_ML_REGION=global ANTHROPIC_VERTEX_PROJECT_ID=p dryq 'endpoint:      aiplatform.googleapis.com:443'"
check "vertex sets the provider flag" "CLOUD_ML_REGION=global ANTHROPIC_VERTEX_PROJECT_ID=p dryq 'CLAUDE_CODE_USE_VERTEX=1'"
cfg '{"model":{"provider":"vertex","base_url":"https://vx.example.com"}}'
check "vertex base_url"              "dryq 'ANTHROPIC_VERTEX_BASE_URL=https://vx.example.com'"
cfg '{"model":{"pass_env":["ANTHROPIC_MODEL"]}}'
check "reserved pass_env is fatal"   "ANTHROPIC_MODEL=x dryerr 'set by agentdev itself'"

echo "shipped example configs validate:"
for ex in "$REPO"/examples/*/agentdev-config.json "$REPO"/templates/skill-eval/agentdev-config.json.example; do
  [[ -f "$ex" ]] || continue
  check "validate $(basename "$(dirname "$ex")")/$(basename "$ex")" "python3 '$REPO/lib/jsoncfg.py' validate '$ex'"
done

echo "mounts:"
cfg "{\"mounts\":{\"read_only\":{\"$T/ref\":\"/external/cfgref\"}}}"
check "config ro mount renders"   "dryq '$T/ref:/external/cfgref:ro'"
cfg "{\"mounts\":{\"read_write\":{\"$T/ref\":\"&\"}}}"
check "config rw & mount renders" "dryq '$T/ref:/ref:rw'"
cfg "{\"mounts\":{\"read_only\":{\"$T/ref\":\"/a\",\"$T/ref/.\":\"/a\"}}}"
check "collision is fatal"        "dryerr 'collision'"
cfg '{"mounts":{"read_only":{"./no-such-dir":"/x"}}}'
check "missing mount source is fatal with message" "dryerr 'not an existing directory'"
cfg "{\"mounts\":{\"read_only\":{\"$T/ref\":\"/home/developer/.ssh\"}}}"
check "reserved target is fatal"  "dryerr 'collision'"

echo "paths are relative to the config file:"
cfg "$T/cfgdir/c.json" '{"workspace":{"source":"."},"mounts":{"read_only":{"rel":"/rel"}}}'
check "-c workspace is the config dir" "dryq '$T/cfgdir:/cfgdir:rw' -c '$T/cfgdir/c.json'"
check "-c mount source is config-relative" "dryq '$T/cfgdir/rel:/rel:ro' -c '$T/cfgdir/c.json'"
cfg "$T/cfgdir/c.json" '{"workspace":{"source":"../ws"}}'
check "workspace.source elsewhere"     "dryq '$T/ws:/ws:rw' -c '$T/cfgdir/c.json'"
cfg "$T/cfgdir/c.json" '{"workspace":{"source":"./missing"}}'
check "missing workspace is fatal"     "dryerr 'workspace.source: not an existing directory' -c '$T/cfgdir/c.json'"
mkdir -p "$T/etc"
cfg "$T/cfgdir/c.json" "{\"workspace\":{\"source\":\"$T/etc\"}}"
check "system-path workspace is fatal" "dryerr 'collides with a system path' -c '$T/cfgdir/c.json'"

echo "prompt:"
printf 'do the thing with "quotes" and $vars and `ticks`\n' > "$T/ws/prompt.txt"
cfg '{}'
check "--prompt mounts the file ro" "dryq ':/home/developer/.agentdev-prompt:ro' --prompt '$T/ws/prompt.txt'"
check "--prompt reads it via cat"   "dryq 'cat.*agentdev-prompt' --prompt '$T/ws/prompt.txt'"
check "--prompt shown in plan"      "dryq 'prompt file:' --prompt '$T/ws/prompt.txt'"
check "--prompt relative to cwd"    "dryq '$T/ws/prompt.txt:/home/developer/.agentdev-prompt:ro' --prompt prompt.txt"
check "--prompt + command is fatal" "dryerr 'cannot be combined' --prompt '$T/ws/prompt.txt' -- bash"
check "missing --prompt is fatal"   "dryerr 'prompt file not found' --prompt '$T/no-such.txt'"
printf 'from config\n' > "$T/cfgdir/task.md"
cfg "$T/cfgdir/c.json" '{"workspace":{"source":"../ws"},"prompt":{"file":"task.md"}}'
check "prompt.file is config-relative" "dryq '$T/cfgdir/task.md:/home/developer/.agentdev-prompt:ro' -c '$T/cfgdir/c.json'"
check "--prompt overrides prompt.file" "dryq '$T/ws/prompt.txt:/home/developer/.agentdev-prompt:ro' -c '$T/cfgdir/c.json' --prompt prompt.txt"
check "prompt.file + command is fatal" "dryerr 'cannot be combined' -c '$T/cfgdir/c.json' -- bash"
cfg "$T/cfgdir/c.json" '{"workspace":{"source":"../ws"},"prompt":{"file":"none.md"}}'
check "missing prompt.file is fatal"   "dryerr 'prompt file not found' -c '$T/cfgdir/c.json'"

echo "json config:"
mkdir -p "$T/ws/sub"
cfg "{\"profile\":{\"mode\":\"profile\",\"name\":\"jp\"},\"workspace\":{\"trust\":\"workspace-only\",\"workdir\":\"sub\"},\"network\":{\"mode\":\"none\"},\"mounts\":{\"read_only\":{\"$T/ref\":\"/external/jref\"}}}"
check "default ./agentdev-config.json read" "dryq 'profile:.*/profiles/jp'"
check "config drives mode"         "dryq 'mode:.*profile'"
check "config drives trust"        "dryq 'trust:.*workspace-only'"
check "config drives network"      "dryq 'network:.*none'"
check "entry folder from config"   "dryq 'entry folder:  /ws/sub'"
check "entry folder sets -w"       "dryq '[-]w /ws/sub'"
check "entry folder sets env"      "dryq 'AGENTDEV_WORKDIR=/ws/sub'"
check "json mount renders"         "dryq '$T/ref:/external/jref:ro'"
check "-c explicit path"           "dryq '/profiles/jp' -c '$T/ws/agentdev-config.json'"
cfg "$T/env.json" '{"network":{"mode":"none"}}'
check "AGENTDEV_CONFIG selects file" "cd '$T' && AGENTDEV_CONFIG='$T/env.json' dryq 'network:       none'"
check "-c beats AGENTDEV_CONFIG"     "cd '$T' && AGENTDEV_CONFIG='$T/nope.json' dryq 'config:.*env.json' -c '$T/env.json'"
check "missing AGENTDEV_CONFIG fatal" "cd '$T' && AGENTDEV_CONFIG='$T/nope.json' dryerr 'config file not found'"
cfg '{"workspace":{"workdir":"nope"}}'
check "bad entry folder is fatal"  "dryerr 'entry folder does not exist'"
check "missing -c file is fatal"   "dryerr 'config file not found' -c '$T/no-such.json'"
check "invalid json is fatal"      "printf '{bad' > bad.json; dryerr 'invalid' -c bad.json"
rm -f bad.json
check "AGENTDEV_MOUNTS is ignored" "cfg '{}'; AGENTDEV_MOUNTS='$T/ref' drynot '$T/ref'"
mkdir -p "$T/fakehome/.agentdev"
printf '{"network":{"mode":"none"}}' > "$T/fakehome/.agentdev/config.json"
check "user config is not layered" "cfg '{}'; HOME='$T/fakehome' dryq 'network:       off'"

echo "bare invocation (no flags):"
# A bare `agentdev` launches from ./agentdev-config.json; with no config it refuses
# with a clear error (not usage). Exercised offline with a podman stub.
BARE="$T/bare"; mkdir -p "$BARE/withconfig" "$BARE/noconfig" "$BARE/bin"
cat > "$BARE/bin/podman" <<'STUB'
#!/bin/bash
echo "PODMAN-STUB-RAN"
STUB
chmod +x "$BARE/bin/podman"
( cd "$BARE/withconfig" && cfg '{"profile":{"clean_root":"'"$BARE"'/clean"},"sandbox":{"ssh":false}}' )
BARE_ENV="PATH='$BARE/bin:$PATH'"
check "bare + config launches"       "cd '$BARE/withconfig' && eval $BARE_ENV '$AD' 2>/dev/null | grep -q PODMAN-STUB-RAN"
check "bare + config shows no usage" "cd '$BARE/withconfig' && ! eval $BARE_ENV '$AD' 2>&1 | grep -q 'Usage:'"
check "bare + no config errors"      "cd '$BARE/noconfig' && eval $BARE_ENV '$AD' 2>&1 | grep -q 'no config file'"
check "bare + no config exits 1"     "cd '$BARE/noconfig' && ! ( eval $BARE_ENV '$AD' >/dev/null 2>&1 )"
check "bare + no config no launch"   "cd '$BARE/noconfig' && ! eval $BARE_ENV '$AD' 2>/dev/null | grep -q PODMAN-STUB-RAN"
check "--dry-run + no config fails"  "cd '$BARE/noconfig' && ! '$AD' --dry-run 2>/dev/null"
check "--help exits 0 with config"   "cd '$BARE/withconfig' && eval $BARE_ENV '$AD' --help | grep -q 'Usage:'"
cd "$T/ws"

echo
echo "RESULT: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
