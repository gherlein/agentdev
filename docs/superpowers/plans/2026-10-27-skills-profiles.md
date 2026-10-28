# Skills Profiles Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let an agentdev config name a bundle of skills (a profile and/or an inline list) and have agentdev materialize exactly that set into the agent's `.claude/skills`, read-only, from one shared store.

**Architecture:** A new `skills` block in the config is validated by the schema and read by `config.sh`. A new `lib/skills.sh` resolves the requested names against the store, validates each is a conforming skill, folds in a persistent home's hand-placed skills (hand-placed wins on collision), copies the final set into one per-run staging directory, and mounts that directory **read-only** at `/home/developer/.claude/skills`. The launcher wires in the call, the mount, the dry-run plan line, and staging cleanup.

**Tech Stack:** bash + python3 (no new dependencies); the existing `jsoncfg.py` schema; podman bind mounts; `tests/matrix.py` (offline dry-run) + `tests/live.sh` (Tier B, live RO enforcement).

**Spec:** [`DESIGN-skills.md`](../../../DESIGN-skills.md)

## Global Constraints

- Build and test only through the Makefile (`make test`, `make lint`, `make test-live`).
- No new runtime dependencies beyond bash + python3 (agentdev's floor).
- Config is validated **fail-closed**; an unknown key or unresolved skill/profile aborts before launch.
- Store default: `${XDG_DATA_HOME:-$HOME/.local/share}/skills`. Profiles dir: `${XDG_CONFIG_HOME:-$HOME/.config}/agentdev/profiles/<name>`.
- Skills are **read-only** in the container (RO bind mount, not file permissions).
- One mount for the whole skills set, regardless of count.
- Comments explain WHY; match the existing `lib/*.sh` style; no emoji in code.

## Review Focus

- A requested skill name absent from the store → fail-closed error naming the skill, never a silent drop. → Task 2.
- A profile file with blank lines and `#` comments → those lines ignored, not treated as skill names. → Task 2.
- A name in both the profile and `include` → deduped, mounted once. → Task 2.
- A persistent home's hand-placed skill colliding with a profile skill of the same name → hand-placed wins, profile's is skipped with a warning. → Task 2 (precedence) + Task 3 (copy).
- A skill bundling an absolute or escaping symlink → omitted and reported on copy, so no host path is exposed into the container. → Task 3.

---

## File Structure

- `lib/jsoncfg.py` (modify) — add the `skills` schema group.
- `lib/config.sh` (modify) — read `skills.*` into globals.
- `lib/skills.sh` (create) — resolve, validate, fold, stage, mount.
- `agentdev` (modify) — source `skills`; call `collect_skills`; add the mount to the podman argv; add the dry-run plan line; clean up staging on exit.
- `tests/matrix.py` (modify) — offline dry-run cases (group G6).
- `tests/live.sh` (modify) — one Tier B case: a mounted skill is present and not writable.
- `README.md`, `docs/testing-plan.md` (modify) — document the `skills` block.

---

### Task 1: Schema + config read

**Files:**
- Modify: `lib/jsoncfg.py` (SCHEMA)
- Modify: `lib/config.sh` (load_config)
- Test: `tests/smoke.sh` (validation cases)

**Interfaces:**
- Produces: config globals `SKILLS_STORE` (string path or empty), `SKILLS_PROFILE` (string name or empty), and array `SKILLS_INCLUDE`.

- [ ] **Step 1: Write the failing test** — in `tests/smoke.sh`, add to the validation section: a config with `"skills": {"store":"/s","profile":"p","include":["a","b"]}` passes `jsoncfg.py validate`; a config with `"skills": {"bogus": 1}` fails validation; a config with `"skills": {"include": "notalist"}` fails validation.
- [ ] **Step 2: Run to verify it fails** — `./tests/smoke.sh` → the three new assertions fail (skills unknown key).
- [ ] **Step 3: Implement** — in `lib/jsoncfg.py` add to `SCHEMA` a `"skills"` group: `{"store": "str", "profile": "str", "include": "str-list"}`. In `lib/config.sh` `load_config`, add: `SKILLS_STORE=$(cfg_path "skills.store" "${XDG_DATA_HOME:-$HOME/.local/share}/skills")` **only when a skills block is present**, else empty; `SKILLS_PROFILE=$(cfg_scalar "skills.profile" "")`; `_read_list "skills.include" SKILLS_INCLUDE`. Gate the store default on `_json has … skills` so a config with no skills block leaves `SKILLS_STORE` empty (no store requirement).
- [ ] **Step 4: Run to verify it passes** — `./tests/smoke.sh` → all pass. `make lint` clean.
- [ ] **Step 5: Commit** — `git add lib/jsoncfg.py lib/config.sh tests/smoke.sh && git commit -m "feat(skills): add skills config schema and read"`

---

### Task 2: Resolve + validate + dry-run plan (no staging)

**Files:**
- Create: `lib/skills.sh`
- Modify: `agentdev` (source `skills`; call resolver; dry-run plan line)
- Test: `tests/matrix.py` (new group G6)

**Interfaces:**
- Consumes: `SKILLS_STORE`, `SKILLS_PROFILE`, `SKILLS_INCLUDE`, `MNT_AGENT_FOLDER`, `AGENT_HOME`, `DRY_RUN`, `register_target` (from mounts.sh).
- Produces (the launcher calls `collect_skills` as the single entry point):
  - `collect_skills` — the umbrella: if `skills_wanted`, resolves the final name set and sets `SKILLS_LIST` (space-joined, for the plan) and `SKILLS_MOUNT=()` (Task 3 fills the mount on real runs). No-op when no skills block.
  - `skills_wanted -> 0` if a skills block is active (profile or include non-empty).
  - `skills_resolve ->` prints the final skill names (one per line); exits non-zero with an `Error:`/`Note:` message on a missing store, missing profile file, unresolved name, or non-conforming requested skill. Precedence: hand-placed names (from `$MNT_AGENT_FOLDER/.claude/skills`) are kept; a profile/include name colliding with one is dropped with a `Note:` warning; profile ∪ include deduped.
  - `skills_is_conforming <dir> -> 0` if `<dir>/SKILL.md` exists and `basename <dir>` matches `^[a-z0-9]([a-z0-9-]*[a-z0-9])?$`.

- [ ] **Step 1: Write the failing test** — in `tests/matrix.py` add group **G6 skills** using the existing helpers. Each case builds a temp store dir with conforming skill dirs (`<name>/SKILL.md` containing `---\nname: <name>\n---\n`) and a config with `skills.store` set, runs `--dry-run`, and asserts:
  - positive: `include:["git-ops","documentation"]` → plan output contains `git-ops` and `documentation` on a `skills:` line;
  - dedup: `profile` (a temp profile file via `XDG_CONFIG_HOME`) listing `git-ops` plus `include:["git-ops"]` → `git-ops` appears once;
  - comments: a profile file with `# comment` and blank lines → only real names resolved;
  - negative: `include:["nope"]` (not in store) → non-zero exit, stderr names `nope`;
  - negative: `profile:"ghost"` with no profile file → non-zero exit, stderr mentions the profile;
  - negative: `skills.store` pointing at a missing dir → non-zero exit;
  - negative: a requested name whose store dir lacks `SKILL.md` → non-zero exit;
  - fold/collision: `MNT_AGENT_FOLDER` with a hand-placed `git-ops/SKILL.md` + profile also offering `git-ops` → plan still lists `git-ops` once and stderr has a `Note:` that the hand-placed one wins.
- [ ] **Step 2: Run to verify it fails** — `python3 ./tests/matrix.py` → G6 fails (no `skills.sh`).
- [ ] **Step 3: Implement** — write `lib/skills.sh` with the functions above. `skills_resolve` reads the profile file at `${XDG_CONFIG_HOME:-$HOME/.config}/agentdev/profiles/$SKILLS_PROFILE` (strip `#` comments and blanks), unions with `SKILLS_INCLUDE`, dedupes, validates each name against `$SKILLS_STORE/<name>` via `skills_is_conforming` (abort on miss), and applies the hand-placed-wins precedence. `collect_skills` sets `SKILLS_LIST` from `skills_resolve` and `SKILLS_MOUNT=()`. In `agentdev`: add `skills` to the `for m in config agents mounts net skills` source loop; after `collect_mounts`, call `collect_skills`; add a dry-run plan line `echo "skills:        ${SKILLS_LIST:-(none)} -> /home/developer/.claude/skills (ro)"`.
- [ ] **Step 4: Run to verify it passes** — `python3 ./tests/matrix.py` → all pass; `make lint` clean.
- [ ] **Step 5: Commit** — `git add lib/skills.sh agentdev tests/matrix.py && git commit -m "feat(skills): resolve profile+include against the store, fail-closed"`

---

### Task 3: Stage + read-only mount + cleanup (real run)

**Files:**
- Modify: `lib/skills.sh` (staging + mount)
- Modify: `agentdev` (mount in argv; cleanup)
- Test: `tests/live.sh` (Tier B case)

**Interfaces:**
- Consumes: the resolved names from Task 2, `register_target`, `AGENT_HOME`.
- Produces: `collect_skills` — when not `DRY_RUN`, creates a staging dir, copies each resolved skill's whole directory into it (hand-placed copied from the home, profile skills from the store; omit absolute/escaping symlinks with a `Note:`), registers `$AGENT_HOME/.claude/skills`, and sets `SKILLS_MOUNT=(-v "$staging:$AGENT_HOME/.claude/skills:ro")` and `SKILLS_STAGING=$staging`.

- [ ] **Step 1: Write the failing test** — in `tests/live.sh` add a case: a temp store with one skill (`demo/SKILL.md`), a config with `skills.include:["demo"]`, run `-- bash -lc 'test -f /home/developer/.claude/skills/demo/SKILL.md && (echo X > /home/developer/.claude/skills/demo/x 2>/dev/null && echo WRITABLE || echo READONLY)'`; assert output has `READONLY` and the SKILL.md is present.
- [ ] **Step 2: Run to verify it fails** — `make test-live` (gated; where podman+image present) → the new case fails (no skills mount yet).
- [ ] **Step 3: Implement** — extend `collect_skills` in `lib/skills.sh` so that when `DRY_RUN != yes` it creates a staging dir, copies each resolved skill's whole directory into it (hand-placed from the home, profile skills from the store; use `cp -a`; drop symlinks that are absolute or resolve outside the skill dir, emitting a `Note:`), registers `$AGENT_HOME/.claude/skills`, and sets `SKILLS_MOUNT=(-v "$staging:$AGENT_HOME/.claude/skills:ro")` and `SKILLS_STAGING=$staging`. In `agentdev`: insert `"${SKILLS_MOUNT[@]}"` into `PODMAN_ARGS` immediately after `"${HOME_MOUNTS[@]}"`, and add `rm -rf "${SKILLS_STAGING:-}"` to `cleanup_run`.
- [ ] **Step 4: Run to verify it passes** — `make test-live` → the case passes; `make test` (offline) still green; `make lint` clean.
- [ ] **Step 5: Commit** — `git add lib/skills.sh agentdev tests/live.sh && git commit -m "feat(skills): stage selected skills and mount read-only"`

---

### Task 4: Documentation

**Files:**
- Modify: `README.md` (Configuration — a `skills` block subsection + the annotated example)
- Modify: `docs/testing-plan.md` (note the new config surface + G6 + the Tier B case)

- [ ] **Step 1: Implement** — add a `### skills — a bundle from the shared store` subsection to the README Configuration section (what it is, `store`/`profile`/`include`, read-only, one mount, the XDG store, profiles dir), and a `skills` entry in the annotated config example. Add the `skills.*` rows to the config-surface table in `docs/testing-plan.md` and mention G6 + the Tier B skills case.
- [ ] **Step 2: Verify** — `make lint` clean; re-read both docs for accuracy against the code.
- [ ] **Step 3: Commit** — `git add README.md docs/testing-plan.md && git commit -m "docs(skills): document the skills config block"`
