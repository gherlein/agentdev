#!/bin/bash
# seed.sh - turn a template into a fresh profile (the "copy" strategy).
# Requires: python3, git; globals PROFILE, TEMPLATE_SOURCE, TEMPLATE_INCLUDE[],
# DIR_NAME, ENC, WS_TRUST, AUTH_MODE, AGENT_NAME, SELFDIR.

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

  cat > "$PROFILE/.gitignore" <<'EOF'
# Secrets must never be versioned or pushed.
.claude/.credentials.json
.claude/policy-limits.json
EOF
}

# git_init_profile - make the profile a git repo with the seed as its first commit.
git_init_profile() {
  [[ "$VCS" == "git" ]] || return 0
  git -C "$PROFILE" init -q
  git -C "$PROFILE" add -A
  git -C "$PROFILE" -c user.name=agentdev -c user.email=agentdev@localhost \
      commit -q -m "seed: ${AGENT_NAME} profile (${MODE})" || true
}

# snapshot_profile MSG - commit the current profile state (post-run).
snapshot_profile() {
  [[ "$VCS" == "git" ]] || return 0
  [[ -d "$PROFILE/.git" ]] || return 0
  git -C "$PROFILE" add -A
  if ! git -C "$PROFILE" diff --cached --quiet 2>/dev/null; then
    git -C "$PROFILE" -c user.name=agentdev -c user.email=agentdev@localhost \
        commit -q -m "${1:-run snapshot}" || true
  fi
}
