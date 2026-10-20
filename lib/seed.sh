#!/bin/bash
# seed.sh - turn a template into a fresh profile (the "copy" strategy).
# Requires: python3; globals PROFILE, TEMPLATE_SOURCE, TEMPLATE_INCLUDE[], DIR_NAME,
# ENC, WS_TRUST, AUTH_MODE, AGENT_NAME, SELFDIR.
#
# agentdev does not version folders. It writes a .gitignore purely as a secrets guard
# so that IF you choose to put the folder under git (or similar) yourself, credentials
# are already excluded. No git commands are ever run by this tool.

# lint_template DIR - returns nonzero (and explains on stderr) if the template is
# malformed. Callers that want fail-closed behavior do: lint_template "$x" || exit 1.
lint_template() {
  local src="$1"
  if [[ ! -d "$src" ]]; then
    echo "Error: template source not found or not a directory: $src" >&2
    return 1
  fi
  if [[ -f "$src/settings.json" ]]; then
    if ! python3 -c "import json,sys; json.load(open('$src/settings.json'))" 2>/dev/null; then
      echo "Error: template settings.json is not valid JSON: $src/settings.json" >&2
      return 1
    fi
  fi
  # Hook scripts must be executable, or the CLI silently ignores them. Hidden files
  # (e.g. a .gitkeep placeholder) are not hooks and are skipped.
  if [[ -d "$src/hooks" ]]; then
    local h
    while IFS= read -r -d '' h; do
      if [[ "$(basename "$h")" == .* ]]; then continue; fi
      if [[ ! -x "$h" ]]; then
        echo "Error: hook is not executable: $h (chmod +x it)" >&2
        return 1
      fi
    done < <(find "$src/hooks" -type f -print0 2>/dev/null)
  fi
  return 0
}

# _write_claude_json PATH - seed a minimal, believable .claude.json, applying trust.
_write_claude_json() {
  local out="$1" seed_fragment="$TEMPLATE_SOURCE/claude.json.seed"
  python3 - "$out" "$seed_fragment" "$DIR_NAME" "$WS_TRUST" <<'PY'
import json, sys, uuid, os
out, fragment, dirname, trust = sys.argv[1:5]
data = {}
if os.path.isfile(fragment):
    try:
        data = json.load(open(fragment))
    except Exception:
        data = {}
data.setdefault("projects", {})
data.setdefault("numStartups", 0)
data.setdefault("hasCompletedOnboarding", True)
data.setdefault("userID", uuid.uuid4().hex)
if trust == "workspace-only":
    data["projects"]["/" + dirname] = {"hasTrustDialogAccepted": True}
with open(out, "w") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
PY
}

# seed_profile - build $PROFILE from the template. Caller guarantees $PROFILE
# does not yet exist (clean/first-named) OR is being --reseed'd (config only).
seed_profile() {
  local reseed="${1:-no}"
  lint_template "$TEMPLATE_SOURCE" || { echo "Error: template failed lint; aborting." >&2; exit 1; }

  mkdir -p "$PROFILE/.claude"

  # Copy the authored config items from the template.
  local item
  for item in "${TEMPLATE_INCLUDE[@]}"; do
    if [[ -e "$TEMPLATE_SOURCE/$item" ]]; then
      cp -a "$TEMPLATE_SOURCE/$item" "$PROFILE/.claude/"
    fi
  done

  if [[ "$reseed" == "reseed" ]]; then
    echo "Re-seeded config into existing profile: $PROFILE" >&2
    return 0
  fi

  # Runtime scaffolding (empty but valid).
  mkdir -p "$PROFILE/.claude/projects/$ENC/memory"
  : > "$PROFILE/.claude/history.jsonl"

  _write_claude_json "$PROFILE/.claude.json"
  _write_gitignore
}

# _write_gitignore - drop a secrets-excluding .gitignore so that if the folder is ever
# versioned externally (by you, not by agentdev), credentials can't be committed.
_write_gitignore() {
  [[ -f "$PROFILE/.gitignore" ]] && return 0
  cat > "$PROFILE/.gitignore" <<'EOF'
# Secrets must never be versioned or pushed.
.claude/.credentials.json
.claude/policy-limits.json
EOF
}

# inherit_host_credentials HOST_CREDS - copy the host's Claude Code subscription
# credentials into the profile (private; excluded by .gitignore). Used by
# auth=inherit-credentials so a named profile reuses the login you already have.
inherit_host_credentials() {
  local host_creds="$1"
  if [[ ! -r "$host_creds" ]]; then
    echo "Error: cannot read host credentials: $host_creds" >&2
    return 1
  fi
  mkdir -p "$PROFILE/.claude"
  install -m 600 "$host_creds" "$PROFILE/.claude/.credentials.json"
  chmod 700 "$PROFILE" 2>/dev/null || true
}

# inherit_host_account HOST_CLAUDE_JSON OUT_CLAUDE_JSON - merge the host's claude.ai
# account linkage into the profile's seeded .claude.json. The copied .credentials.json
# holds the OAuth tokens, but Claude Code only treats a session as a signed-in claude.ai
# subscription when the account block (oauthAccount) is also present; without it the
# token is inert — no connectors, no managed settings, no org policy. We copy only the
# non-secret account metadata (no tokens; those live in .credentials.json), so a named
# profile actually reuses the host login instead of just carrying a dead token.
#
# Best-effort: a missing/unreadable host file, or one with no account block, is not an
# error (the user just signs in inside the profile). Note: this cannot add an OAuth
# scope the host token never had (e.g. a "missing user:profile scope" host login stays
# missing it); it only reconstitutes the sign-in a properly scoped host login already has.
inherit_host_account() {
  local host_json="$1" out_json="$2"
  if [[ ! -r "$host_json" ]]; then
    echo "Note: no readable host ~/.claude.json; sign in inside the profile if subscription features are missing." >&2
    return 0
  fi
  python3 - "$host_json" "$out_json" <<'PY' || true
import json, sys

host_path, out_path = sys.argv[1], sys.argv[2]

# Account-linked, non-secret fields. Tokens are NOT here (they are in
# .credentials.json); this is deliberately an allowlist, never the whole file.
ACCOUNT_KEYS = ("oauthAccount", "hasAvailableSubscription", "userID")

try:
    with open(host_path) as fh:
        host = json.load(fh)
except Exception:
    sys.exit(0)  # best-effort; nothing to inherit

if not isinstance(host.get("oauthAccount"), dict):
    sys.stderr.write(
        "Note: host ~/.claude.json has no oauthAccount block; "
        "sign in inside the profile ('claude auth login') for subscription features.\n")
    sys.exit(0)

try:
    with open(out_path) as fh:
        out = json.load(fh)
except Exception:
    out = {}

for key in ACCOUNT_KEYS:
    if key in host:
        out[key] = host[key]

with open(out_path, "w") as fh:
    json.dump(out, fh, indent=2)
    fh.write("\n")
PY
}
