#!/bin/bash
# skills.sh - materialize a bundle of skills from the shared store into the agent's
# .claude/skills, read-only. A `skills` block (a profile and/or an inline include list)
# names skills in one flat store (the Skill Embedding Standard store). agentdev resolves
# the set, folds in a persistent home's hand-placed skills (hand-placed wins on a name
# collision), copies the final set into a per-run staging dir, and mounts that dir
# read-only at .claude/skills.
#
# Config is the source of truth: the set is recomputed every launch and nothing persists.
# Read-only is a bind mount, not file permissions, because the agent can reach
# container-root and would defeat permission-based immutability (see docs/containment-testing.md).
#
# Produces: SKILLS_LIST (space-joined final names, for the plan), SKILLS_MOUNT (array),
# SKILLS_STAGING (path or empty). Requires the config globals SKILLS_STORE/PROFILE/INCLUDE,
# MNT_AGENT_FOLDER, AGENT_HOME (agents.sh), DRY_RUN, and register_target (mounts.sh).
# Staging/copy side effects are added in a later step and skipped when DRY_RUN=yes.

SKILLS_DEST="/home/developer/.claude/skills"
SKILLS_NAME_RE='^[a-z0-9]([a-z0-9-]*[a-z0-9])?$'

# skills_wanted -> 0 if a skills block selects anything (a profile or any include).
skills_wanted() { [[ -n "$SKILLS_PROFILE" || ${#SKILLS_INCLUDE[@]} -gt 0 ]]; }

# skills_is_conforming DIR -> 0 if DIR is a conforming skill: a SKILL.md at its root and
# a directory name that is a valid skill name.
skills_is_conforming() {
  local dir="$1" base
  base="$(basename "$dir")"
  [[ -f "$dir/SKILL.md" && "$base" =~ $SKILLS_NAME_RE ]]
}

# _skills_profile_names - print the skill names in the profile file (one per line),
# stripping "#" comments and surrounding whitespace. Returns non-zero if a profile is
# named but its file is missing.
_skills_profile_names() {
  [[ -n "$SKILLS_PROFILE" ]] || return 0
  local pf="${XDG_CONFIG_HOME:-$HOME/.config}/agentdev/profiles/$SKILLS_PROFILE"
  [[ -f "$pf" ]] || { echo "Error: skills.profile '$SKILLS_PROFILE': no profile file at $pf" >&2; return 1; }
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"; line="${line//[[:space:]]/}"
    [[ -n "$line" ]] && printf '%s\n' "$line"
  done < "$pf"
  return 0   # the while-read loop ends non-zero at EOF; the function itself succeeded
}

# skills_resolve - print the final skill names (one per line). Hand-placed skills already
# in the agent home are kept and win collisions; requested names (profile + include) are
# deduped and validated against the store. Returns non-zero (fail-closed) on a missing
# store, missing profile file, unresolved name, or non-conforming requested skill.
skills_resolve() {
  skills_wanted || return 0
  [[ -n "$SKILLS_STORE" && -d "$SKILLS_STORE" ]] || {
    echo "Error: skills.store: not a directory: ${SKILLS_STORE:-(unset)}" >&2; return 1; }

  local prof_names
  prof_names="$(_skills_profile_names)" || return 1

  local -A seen=(); local -a final=(); local name d req
  if [[ -n "$MNT_AGENT_FOLDER" && -d "$MNT_AGENT_FOLDER/.claude/skills" ]]; then
    for d in "$MNT_AGENT_FOLDER/.claude/skills"/*/; do
      [[ -d "$d" ]] || continue
      skills_is_conforming "$d" || continue
      name="$(basename "$d")"
      [[ -n "${seen[$name]:-}" ]] && continue
      seen[$name]=home; final+=("$name")
    done
  fi

  for req in $prof_names "${SKILLS_INCLUDE[@]:-}"; do
    [[ -n "$req" ]] || continue
    if [[ "${seen[$req]:-}" == home ]]; then
      echo "Note: skills '$req': a hand-placed skill in the agent home wins over the store copy." >&2
      continue
    fi
    [[ -n "${seen[$req]:-}" ]] && continue
    skills_is_conforming "$SKILLS_STORE/$req" || {
      echo "Error: skills '$req': not a conforming skill in the store ($SKILLS_STORE/$req)" >&2; return 1; }
    seen[$req]=store; final+=("$req")
  done

  printf '%s\n' "${final[@]:-}"
}

# _skills_copy SRC DEST - copy a whole skill directory, then drop any symlink that is
# absolute or resolves outside the copied skill: it would dangle in the container or
# expose a host path, so a copier omits it (Skill Embedding Standard, §5.4).
_skills_copy() {
  local src="$1" dest="$2" link target rp drp
  cp -a "$src" "$dest"
  drp="$(realpath -m "$dest")"
  while IFS= read -r -d '' link; do
    target="$(readlink "$link")"
    rp="$(realpath -m "$link")"
    if [[ "$target" == /* || ( "$rp" != "$drp" && "$rp" != "$drp"/* ) ]]; then
      echo "Note: skills '$(basename "$dest")': dropped symlink $(basename "$link") -> $target (absolute or escapes the skill)." >&2
      rm -f "$link"
    fi
  done < <(find "$dest" -type l -print0)
}

# collect_skills - the single entry point the launcher calls. Resolves the final name
# set into SKILLS_LIST, and on a real run copies each skill into a staging dir and mounts
# it read-only at .claude/skills. A missing/invalid selection aborts the launch, in
# dry-run too. Read-only is a bind mount (not file perms) so even container-root cannot
# mutate a skill (see docs/containment-testing.md).
collect_skills() {
  SKILLS_LIST=""; SKILLS_MOUNT=(); SKILLS_STAGING=""
  skills_wanted || return 0
  local out; out="$(skills_resolve)" || exit 1
  local -a names=(); local n
  while IFS= read -r n; do [[ -n "$n" ]] && names+=("$n"); done <<< "$out"
  SKILLS_LIST="${names[*]:-}"

  [[ "$DRY_RUN" == yes || ${#names[@]} -eq 0 ]] && return 0

  SKILLS_STAGING="$(mktemp -d)"
  local src
  for n in "${names[@]}"; do
    if [[ -n "$MNT_AGENT_FOLDER" && -d "$MNT_AGENT_FOLDER/.claude/skills/$n" ]]; then
      src="$MNT_AGENT_FOLDER/.claude/skills/$n"
    else
      src="$SKILLS_STORE/$n"
    fi
    _skills_copy "$src" "$SKILLS_STAGING/$n"
  done
  register_target "$SKILLS_DEST" "skills (read-only bundle)"
  SKILLS_MOUNT=(-v "$SKILLS_STAGING:$SKILLS_DEST:ro")
  printf 'Mounting (read-only): %d skill(s) -> %s\n' "${#names[@]}" "$SKILLS_DEST" >&2
}
