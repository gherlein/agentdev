# MCP config control — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an `mcp` config key — an array of host paths to MCP config files — that agentdev copies into the container and wires the agent to load as a strict allowlist (enforced for one-shot runs, advisory for interactive).

**Architecture:** Mirrors the `skills` feature. A new `lib/mcp.sh` resolves + validates the listed files (pure, fail-closed), then on a real run copies them into one per-run staging dir mounted read-only and emits the `--strict-mcp-config --mcp-config …` flags. One-shot splices the flags into the headless `claude` command; interactive exposes them via `AGENTDEV_MCP_ARGS` (soft). Config is the source of truth, recomputed each launch; read-only is a bind mount (containment-grounded).

**Tech Stack:** bash (lib/*.sh, agentdev), python3 (lib/jsoncfg.py), pytest-free test harness (tests/smoke.sh, tests/matrix.py, tests/live.sh), Makefile.

**Spec:** `DESIGN-mcp.md` (repo root).

## Global Constraints

- Build/test ONLY through the Makefile: `make test` (smoke + matrix, offline), `make lint`, `make test-live` (gated). Never run python/bash test files directly as the deliverable check.
- `set -u` everywhere: expand possibly-empty arrays as `"${arr[@]:-}"`.
- A `while read` loop ends non-zero at EOF; a function whose last statement is such a loop must `return 0` explicitly.
- `exit` inside a `$(...)` command substitution exits only the subshell; resolver functions use `return 1` and the caller does `out="$(fn)" || exit 1`.
- External input = the array of paths + each file's contents. Validate at the boundary, fail closed, and **never echo file contents** (MCP01: a literal secret must not reach logs). Paths are passed as argv to `cp`/`podman`/`claude`, never interpolated into a `bash -c` string (MCP05).
- claude-only: strict is always on for the one-shot path; no `strict` config key.
- Commit after each task. Attribution: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- `gherlein:clean-comments` (WHY not WHAT), no emoji, meaningful names.

## Review Focus

Input classes the tests below must each pin:

- **Missing / unreadable / non-file path** → launch aborts naming the path, in dry-run too. → Task 2 test `mcp missing file`, Task 3 matrix `mcp missing file (dry-run)`.
- **Malformed JSON, or no top-level `mcpServers` object** → aborts naming the file; contents never logged. → Task 2 tests `mcp bad json` / `mcp no mcpServers`, and a code check that the error message carries only the path.
- **`mcp` block with a one-shot `omp`/`pi` agent** → aborts (only claude has the surface). → Task 3 matrix `mcp rejects non-claude`.
- **Basename collision across two listed files** → unique container names (`00-`, `01-` prefixes), both mounted, array order preserved for merge precedence. → Task 3 matrix `mcp basename collision`.
- **`"mcp": []` deny-all vs absent key** → `[]` yields `--strict-mcp-config` with no `--mcp-config` (zero servers); absent yields no MCP flags at all. → Task 3 matrix `mcp deny-all` and `mcp absent`.
- **Read-only mount holds against the agent** → the staged file is present and not writable inside. → Task 4 live `mcp (read-only mount)`.

---

### Task 1: Schema + config read

**Files:**
- Modify: `lib/jsoncfg.py` (SCHEMA)
- Modify: `lib/config.sh` (read block + header comment)
- Test: `tests/smoke.sh` (new "mcp schema" block)

**Interfaces:**
- Produces: `MCP_PRESENT` (`yes`/`no`), `MCP_FILES` (bash array of raw path strings, unanchored). Schema key `mcp` of kind `str-list`.

- [ ] **Step 1: Write the failing test** — in `tests/smoke.sh`, a "mcp schema" block: a config with `"mcp": ["a.json"]` passes `jsoncfg.py validate`; `"mcp": "a.json"` (string) fails; `"mcp": [1]` (non-string element) fails; `"mcp": {}` (object) fails.

- [ ] **Step 2: Run it, verify it fails** — Run: `make test` (or `bash tests/smoke.sh`). Expected: the new assertions fail (string/object currently accepted — `mcp` unknown key actually *fails* validation today, so assert the specific pass/fail: valid array must PASS, which fails now because `mcp` is an unknown key).

- [ ] **Step 3: Add `"mcp": "str-list"`** to `SCHEMA` in `lib/jsoncfg.py`, immediately after the `skills` block.

- [ ] **Step 4: Read the block in `lib/config.sh`** — after the skills block (~line 109), add:
  ```bash
  # --- mcp (optional; an allowlist of MCP config files to stage) ---
  MCP_PRESENT=no
  if [[ "$CONFIG_PRESENT" == yes ]] && _json has "$JSON_CONFIG" "mcp"; then
    MCP_PRESENT=yes
  fi
  _read_list "mcp" MCP_FILES
  ```
  Add `MCP_PRESENT` and `(MCP_FILES is an array)` to the Globals header comment.

- [ ] **Step 5: Run tests, verify pass** — Run: `make test`. Expected: smoke mcp-schema block passes; matrix unchanged.

- [ ] **Step 6: Commit** — `feat(mcp): add mcp config schema and read`.

---

### Task 2: Resolve + validate (pure, fail-closed)

**Files:**
- Create: `lib/mcp.sh`
- Test: `tests/smoke.sh` (new "mcp file validation" block)

**Interfaces:**
- Consumes: `MCP_PRESENT`, `MCP_FILES` (Task 1); `anchor_path` (config.sh).
- Produces: `MCP_DEST="/home/developer/.agentdev-mcp"`; `mcp_wanted()` → 0 iff `MCP_PRESENT==yes`; `mcp_resolve()` → prints resolved absolute host paths one per line (empty output + status 0 for `[]`), `return 1` fail-closed on any missing/unreadable/non-file/malformed/no-`mcpServers` file; `_mcp_validate_file FILE` → 0 iff FILE is valid JSON with a top-level `mcpServers` object (message carries the path only).

- [ ] **Step 1: Write the failing test** — in `tests/smoke.sh`, a "mcp file validation" block that sources `lib/mcp.sh` and `lib/config.sh` helpers, then: a well-formed `{"mcpServers":{"x":{"command":"true"}}}` → `_mcp_validate_file` returns 0; a malformed-JSON file → non-zero and stderr names the path; a `{"foo":{}}` (no mcpServers) → non-zero; a `{"mcpServers":[]}` (not an object) → non-zero. Assert the error text contains the file path and does **not** contain the file's inner contents.

- [ ] **Step 2: Run it, verify it fails** — Run: `make test`. Expected: FAIL (`lib/mcp.sh` / `_mcp_validate_file` not defined).

- [ ] **Step 3: Implement `lib/mcp.sh`** with `MCP_DEST`, `mcp_wanted`, `_mcp_validate_file` (uses `_json check` for parse + a one-line `python3 -c` isinstance(dict) check on `mcpServers`; echoes `Error: mcp '<path>': …` only), and `mcp_resolve` (for each entry: `anchor_path`, require regular readable file else `return 1`, `_mcp_validate_file` else `return 1`, then `printf '%s\n'`). `mcp_resolve` begins `mcp_wanted || return 0`.

- [ ] **Step 4: Run tests, verify pass** — Run: `make test`. Expected: the mcp validation block passes; nothing else changes (mcp.sh not yet sourced by the launcher).

- [ ] **Step 5: Commit** — `feat(mcp): resolve and validate mcp config files, fail-closed`.

---

### Task 3: Stage, flags, and launcher wiring

**Files:**
- Modify: `lib/mcp.sh` (add `collect_mcp`, `_mcp_copy`)
- Modify: `lib/agents.sh` (`agent_headless_cmd` extra-flags arg)
- Modify: `agentdev` (source order, agent-gate, reorder COMMAND build, PODMAN_ARGS, cleanup, dry-run plan, interactive hint)
- Test: `tests/matrix.py` (new G7 group)

**Interfaces:**
- Consumes: `mcp_resolve`, `MCP_DEST`, `MCP_PRESENT` (Task 2); `register_target` (mounts.sh); `DRY_RUN`, `OS_AGENT`, `RUN_MODE`.
- Produces: `collect_mcp()` → sets `MCP_FLAGS` (container-side flag string: `--strict-mcp-config [--mcp-config $MCP_DEST/NN-base …]`), `MCP_MOUNT` (array, empty for deny-all/dry-run), `MCP_STAGING` (path or empty), `MCP_FILES_LIST` (plan string). `agent_headless_cmd NAME PROMPT [EXTRA_FLAGS]` splices EXTRA_FLAGS for claude only.

- [ ] **Step 1: Write the failing tests** — in `tests/matrix.py`, a G7 group asserting on `--dry-run` output:
  - `mcp one-shot flags`: one-shot claude + `mcp:[good.json]` → podman command contains `--strict-mcp-config` and `--mcp-config /home/developer/.agentdev-mcp/00-good.json` inside the headless `claude … -p` command.
  - `mcp deny-all`: one-shot + `mcp:[]` → contains `--strict-mcp-config`, contains no `--mcp-config`.
  - `mcp absent`: one-shot, no mcp key → no `--strict-mcp-config`, no `AGENTDEV_MCP_ARGS`.
  - `mcp multiple + order`: `mcp:[a.json,b.json]` → `--mcp-config …/00-a.json` precedes `--mcp-config …/01-b.json`.
  - `mcp basename collision`: `mcp:[dir1/s.json, dir2/s.json]` → `00-s.json` and `01-s.json` both present (distinct).
  - `mcp interactive env`: interactive + `mcp:[good.json]` → podman command has `-e AGENTDEV_MCP_ARGS=…--strict-mcp-config…`, and the container command is `bash` (no headless injection).
  - `mcp rejects non-claude` (negative): one-shot `agent:omp` + `mcp:[good.json]` → exit non-zero, message names the agent.
  - `mcp missing file` (negative): `mcp:[/no/such.json]` → exit non-zero naming the path.

- [ ] **Step 2: Run them, verify they fail** — Run: `make test`. Expected: FAIL (`collect_mcp` unused; no flags in output).

- [ ] **Step 3: Implement.**
  - `lib/mcp.sh`: `_mcp_copy SRC DEST` (plain `cp` of a single file; no symlink walk — these are files, not trees). `collect_mcp`: init the four globals; `mcp_wanted || return 0`; `out="$(mcp_resolve)" || exit 1`; read host paths into an array; build `MCP_FLAGS="--strict-mcp-config"` and, per file at index `i`, container name `$(printf '%02d-%s' "$i" "$(basename "$f")")`, append ` --mcp-config $MCP_DEST/$cname`; set `MCP_FILES_LIST`; `[[ "$DRY_RUN" == yes ]] && return 0`; if any files, `MCP_STAGING="$(mktemp -d)"`, copy each to `$MCP_STAGING/$cname`, `register_target "$MCP_DEST" "mcp (read-only config)"`, `MCP_MOUNT=(-v "$MCP_STAGING:$MCP_DEST:ro")`, print `Mounting (read-only): N mcp config file(s) -> $MCP_DEST` to stderr.
  - `lib/agents.sh`: `agent_headless_cmd` takes optional `$3`; for `claude`, insert `${3:+$3 }` between `--dangerously-skip-permissions` and `-p`. omp/pi unchanged.
  - `agentdev`: add `mcp` to the `for m in config agents mounts net skills` source loop; in the one-shot block after the `agent_known` check add the agent-gate `[[ "$MCP_PRESENT" == yes && "$OS_AGENT" != claude ]] && { echo "Error: an mcp block requires the claude agent (omp/pi have no --mcp-config surface); remove mcp or set one-shot.agent=claude." >&2; exit 1; }`; move the one-shot `envload`/`COMMAND=` construction to **after** `collect_mcp`, passing `"$MCP_FLAGS"` as the 3rd arg to `agent_headless_cmd`; call `collect_mcp` right after `collect_skills`; add a `MCP_ENV=()` set to `(-e "AGENTDEV_MCP_ARGS=$MCP_FLAGS")` when `-n "$MCP_FLAGS"`; insert `"${MCP_MOUNT[@]}"` after `"${SKILLS_MOUNT[@]}"` and `"${MCP_ENV[@]}"` near the other `-e` lines in `PODMAN_ARGS`; add `rm -rf "${MCP_STAGING:-}"` to `cleanup_run`; add the dry-run plan line `mcp_wanted && echo "mcp:           ${MCP_FILES_LIST:-(deny-all; no servers)} -> $MCP_DEST (ro); strict"`; for interactive runs when `mcp_wanted`, print one stderr hint line that the flags are in `$AGENTDEV_MCP_ARGS`.

- [ ] **Step 4: Run tests, verify pass** — Run: `make test`. Expected: G7 passes; G1-G6 unchanged. Run `make lint`; expected clean.

- [ ] **Step 5: Commit** — `feat(mcp): stage config files and wire strict allowlist`.

---

### Task 4: Live read-only proof + docs

**Files:**
- Modify: `tests/live.sh` (new "mcp (read-only mount)" case)
- Modify: `README.md` (annotated example + `### mcp` subsection)
- Modify: `docs/testing-plan.md` (config surface row, G7, Tier B case)

**Interfaces:**
- Consumes: the full feature (Task 3).

- [ ] **Step 1: Write the failing test** — in `tests/live.sh` (Tier B), an "mcp (read-only mount)" case: write a store file `m.json` = `{"mcpServers":{"demo":{"command":"true"}}}`, run `adev` with `mcp:["…/m.json"]` and `-- bash -lc` probe asserting `/home/developer/.agentdev-mcp/00-m.json` exists and is NOT writable (`touch` fails / `READONLY`).

- [ ] **Step 2: Run it** — Run: `make test-live` (gated on podman + image; skips otherwise). Expected: with podman, the case runs and currently FAILS or the mount is absent before Task 3 is on this branch — since Task 3 is already merged into the branch, Expected: PASS once written; if podman unavailable, SKIP (record the skip).

- [ ] **Step 3: Implement** — the live case per Step 1; README gets the `mcp` array in the annotated config example and a `### mcp — a strict allowlist of MCP config files` subsection (what, why, one-shot-enforced vs interactive-soft, `${VAR}` secrets convention, `[]` deny-all); `docs/testing-plan.md` gets `mcp` in the config-surface table, G7 in the Tier A list, and the mcp case in the Tier B list.

- [ ] **Step 4: Verify** — Run: `make test` (offline, must stay green) and `make lint`. Run `make test-live` if podman present. Expected: offline green; live mcp case passes or SKIPs.

- [ ] **Step 5: Commit** — `docs(mcp): document the mcp config block and add live proof`.

## Self-Review

- **Spec coverage:** goals (one key names the files ✓ T1/T3; one-shot allowlist ✓ T3; config source-of-truth/recomputed ✓ T3 collect each launch; agentdev does the copying ✓ T3; fail closed ✓ T2/T3; `${VAR}` secrets ✓ T4 docs) and non-goals (connectors untouched — nothing added; interactive soft ✓ T3 env+hint; no installer — config only; claude-only ✓ T3 gate) all map to tasks.
- **Type consistency:** `MCP_PRESENT`/`MCP_FILES` (T1) → `mcp_wanted`/`mcp_resolve` (T2) → `collect_mcp`/`MCP_FLAGS`/`MCP_MOUNT`/`MCP_STAGING` (T3). `agent_headless_cmd` 3rd arg consistent T3. `MCP_DEST` defined once in mcp.sh.
- **Review Focus:** every item above pinned to a named test.
- **Proportion:** four tasks, each an independently reviewable deliverable; no code block longer than the decision it fixes.
- **test-as-guardrails edge matrix:** boundary (missing/empty path), nil/empty (`[]` deny-all, absent), error propagation (fail-closed `return 1` → `|| exit 1`), resource (per-run staging cleaned on exit), network (out of scope — stated as the backstop, not tested as a boundary here). No network API in this project → no api-canary.
