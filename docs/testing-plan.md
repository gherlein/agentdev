# Testing plan: profile-option permutations

agentdev has a large option surface (mode, auth, trust, network, mounts,
workspace, sandbox, template, modifiers). The full cartesian product is
thousands of combinations, but almost all *correctness* lives in the **settled
plan** — which `--dry-run` produces with no container, no network, and no real
credentials. So we split testing into a cheap, near-exhaustive **offline tier**
and a small, gated **live tier**.

## The option surface

| Option | Values | Validity constraints |
|---|---|---|
| mode | clean, remember, profile | — |
| auth | auto, api-key-env, interactive, inherit-credentials | inherit-credentials ⇒ profile only (else downgrades); api-key-env ⇒ key set |
| trust | skip-permissions, workspace-only, prompt | — |
| net | off, allowlist, none | allowlist ⇒ non-empty allowlist; mitm ⇒ allowlist |
| net.mitm | on, off | — |
| workspace | rw, ro | — |
| confirm_rw | on, off | (+ --rw-allow pre-approvals) |
| sandbox.ssh | on, off | — |
| extra mounts | ro, rw, toml, env, dev, collision, reserved | collisions + reserved targets are errors |
| template | default, skill-eval, custom | must lint |
| modifiers | --eval, --keep, --reseed | --keep ⇒ clean; --reseed ⇒ existing profile |
| command | shell vs `-- cmd` | — |

## Tier A — offline plan tests (the bulk)

Each case runs `agentdev … --dry-run` in a throwaway `AGENTDEV_HOME` + temp
workspace + dummy `ANTHROPIC_API_KEY`. No containers, no network, no real
credentials, so it is safe to run exhaustively and in CI with no podman.

We assert **invariants** on the dry-run output (properties), not golden text —
golden breaks on run-ids, tmp paths, and image digests.

### Taming the explosion

- **Validity model first** — encode the constraints above so the generator skips
  meaningless combos (e.g. inherit-credentials + clean) and routes them to the
  negative suite instead.
- **All-pairs (pairwise) coverage** for the big matrix — every pair of option
  values appears together in some case. This catches the large majority of
  interaction bugs in a few dozen cases instead of thousands.
- **Exhaustive** only on the small, security-sensitive **sandbox sub-space**
  (`net × workspace × confirm_rw × ssh × eval`) — small enough to run fully.

### Invariants (the oracle)

Per-option properties the dry-run plan must satisfy:

- `workspace=ro` ⇔ `-v <pwd>:/<dir>:ro`; `rw` ⇔ `:rw`.
- `net=none` ⇔ `--network none`; `net=allowlist` ⇔ `--network agentdev-int-*`
  **and** an `HTTPS_PROXY=` env **and** no second network; `net=off` ⇔ no
  `--network`.
- `sandbox.ssh=false` ⇔ no `/.ssh:` and no `/ssh-agent` in the args.
- `--eval` ⇔ the whole bundle (allowlist + ro workspace + confirm_rw +
  api-key-env + workspace-only trust + no ssh); explicit flags still override it.
- `mode=clean` ⇔ `cleanup: yes` unless `--keep`; profile ⇒ no cleanup.
- auth `auto` resolves per the documented table (key → api-key-env; profile +
  host creds → inherit-credentials; else interactive).
- **Cross-cutting safety invariant (every case):** no mount targets a reserved
  path; exactly one `-v` targets the workspace; the container command is `bash`
  xor the passed `-- cmd`.

### Negative suite (must exit non-zero with a specific message)

allowlist + empty list; api-key-env with no key; a reserved-target mount; two
mounts on the same target; a workspace-name collision (`/etc`, `/home`, …); an
unknown `--net` / `--trust` / `--auth` value; `--reseed` on a nonexistent
profile.

## Tier B — live behavioral tests (small, gated)

A curated ~12-case matrix that actually launches containers and asserts policy is
*enforced*, not just *planned*. Each is `agentdev … -- bash -lc '<probe>'`:

- **ro workspace** → `touch /<dir>/x` fails.
- **net=none** → `curl -m5 https://example.com` fails.
- **net=allowlist** → an allowed host succeeds, a denied host 403s/fails, and
  `agentdev report` shows the DENY.
- **confirm_rw, no TTY, with an rw mount** → run refused (fail-closed); with
  `--rw-allow` → allowed.
- **sandbox.ssh=false** → `/home/developer/.ssh` absent.
- **skills provisioned** (`sm --copy`) → the skill dir is present inside.
- **single-instance** → a second `--profile X` while one holds it is refused;
  `profiles gc` reaps an orphan.
- **auth inherit-credentials** → `claude doctor` reports signed in. Needs real
  credentials → manual/optional, not CI.

Gate on `command -v podman` + the image present; skip (not fail) otherwise. Runs
behind `make test-live`, never in the default offline suite.

## Harness

- **Matrix spec** — `tests/matrix.py` defines each option's values + the validity
  constraints, and emits three case sets: the pairwise valid set, the exhaustive
  sandbox set, and the explicit negative set.
- **Offline runner** — `tests/matrix_offline.sh` (or a Python runner) sets up a
  throwaway env per case, runs `agentdev --dry-run`, and evaluates the invariant
  predicates; on failure it prints the exact option set and the dry-run output.
- **Live runner** — `tests/matrix_live.sh`, gated, runs the Tier B probes.
- **Golden backstop** — a normalizer strips run-ids/tmp paths/digests so a few
  representative cases can also be snapshot-compared as a regression catch.
- Integration: `make test` runs the offline suite (extends today's `smoke.sh`);
  `make test-live` runs Tier B.

## CI

- **Offline matrix** — GitHub Actions on every push (no podman needed).
- **Live tier** — a separate podman-enabled job (nightly or on-label); the
  auth-inherit live check stays manual.

## Phasing

1. Validity model + offline invariant runner (`matrix.py` + runner), wired into
   `make test`. Highest value: exhaustive plan coverage, fast, deterministic.
2. Pairwise generator + negative suite.
3. Live Tier B behind `make test-live` + the CI job.
4. Golden snapshots (normalized) as a regression backstop.
