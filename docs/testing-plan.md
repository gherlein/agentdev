# Testing plan

agentdev has a large config surface (mode, auth, trust, model, network, mounts,
workspace, sandbox, template). The full cartesian product is thousands of
combinations, but almost all *correctness* lives in the **settled plan** — which
`--dry-run` produces with no container, no network, and no real credentials. So we
split testing into a cheap, near-exhaustive **offline tier** and small, gated **live
tiers**.

Every launch is driven by a config file (the only CLI options are `-c`, `--dry-run`,
and `--prompt`), so each test writes a config and runs `agentdev -c <cfg> …`.

## The config surface

| Key | Values | Validity constraints |
|---|---|---|
| `profile.mode` | clean, remember, profile | profile ⇒ `profile.name` set |
| `auth.mode` | auto, api-key-env, interactive, inherit-credentials | inherit-credentials ⇒ profile only (else aborts fail-closed); api-key-env ⇒ key set |
| `workspace.trust` | skip-permissions, workspace-only, prompt | — |
| `model.provider` | anthropic, bedrock, vertex | non-anthropic ⇒ `auth.mode: auto` + required `pass_env` |
| `network.mode` | off, allowlist, none | allowlist ⇒ non-empty allow **and** the model endpoint allowed; mitm ⇒ allowlist |
| `mounts.workspace` | rw, ro | — |
| `mounts.confirm_rw` | true, false | (+ `mounts.rw_allow` pre-approvals) |
| `sandbox.ssh/usb/host_ca` | true, false | — |
| mounts | read_only, read_write, devices, collision, reserved, missing-source | collisions, reserved targets, and missing sources are errors |

## Tier A — offline plan tests (the bulk)

`tests/smoke.sh` and `tests/matrix.py`, run by `make test` / `make run-tests`. Each
case writes a config and runs `agentdev -c <cfg> --dry-run` in a throwaway HOME + temp
workspace + dummy `ANTHROPIC_API_KEY`. No containers, no network, no real credentials,
so it runs exhaustively in CI with no podman. We assert **invariants** on the dry-run
output (properties), not golden text — golden breaks on run-ids, tmp paths, and digests.

- **`tests/smoke.sh`** — config resolution (`-c` / `$AGENTDEV_CONFIG` / `./default`),
  **strict validation** (unknown key, retired key, wrong type, bad enum, `//` comments),
  removed-flag migration errors, the absence of all subcommands, seeding (via the
  seeder directly), model selection (id / provider / base_url / pass_env / endpoint
  interlock), mounts (config maps, `&`, collisions, reserved, missing source, devices),
  paths relative to the config file, the one-shot prompt (`--prompt` and `prompt.file`),
  and the shipped example configs validating.
- **`tests/matrix.py`** — the option matrix: G1 (mode × auth × trust), G1b (auto
  resolution), G2 (sandbox: net × workspace × ssh × confirm_rw, exhaustive), G3 (the
  locked-down `examples/isolated` config), G4 (negatives), plus a cross-cutting safety
  invariant on every positive case.

### Key invariants

- `mounts.workspace: "ro"` ⇔ `:/<dir>:ro`; `rw` ⇔ `:rw`.
- `network.mode: "none"` ⇔ `--network none`; `allowlist` ⇔ `--network agentdev-int-*`
  **and** an `HTTPS_PROXY=` env; `off` ⇔ no `--network`.
- `sandbox.ssh: false` ⇔ no `/.ssh:` and no `/ssh-agent`; `sandbox.usb: false` ⇔ no
  `/dev/bus/usb`; `sandbox.host_ca: false` ⇔ no CA env.
- `profile.mode: clean` ⇔ `cleanup: yes` unless `profile.keep`; profile ⇒ no cleanup.
- auth `auto` resolves per the documented table (key → api-key-env; profile + host creds
  → inherit-credentials; else interactive).
- the forwarded API key / `pass_env` secrets never appear in the plan (passed by name).
- **safety (every case):** exactly one `-v` targets the workspace; the API key value is
  never printed.

### Negative suite (must exit non-zero with a specific message)

Unknown key, retired key (e.g. `profile.default_mode`), wrong type, bad enum value,
allowlist with an empty list, allowlist that excludes the model endpoint, api-key-env
with no key, a reserved-target mount, two mounts on the same target, a missing mount
source, a workspace-name collision (`/etc`, `/home`, …), a prompt combined with a
`-- command`, and a removed flag (`--clean`, `--net`, …) naming the config key to use.

## Tier B — live behavioral tests (small, gated)

`tests/live.sh` (`make test-live`) launches real containers and asserts policy is
*enforced*, not just planned. Each probe runs `agentdev -c <cfg> -- bash -lc '<probe>'`
with a per-case config (built by the `adev` helper):

- **ro workspace** → `touch /<dir>/x` fails; rw → succeeds.
- **network none** → `curl` fails; **allowlist** → an allowed host succeeds, a denied
  host 403s/fails.
- **confirm_rw, no TTY, rw mount** → run refused (fail-closed); with `mounts.rw_allow`
  → allowed.
- **sandbox.ssh=false** → `/home/developer/.ssh` absent.
- **skills provisioned** → a skill dropped into the (plain-folder) profile is present
  inside.
- **single-instance** → a second run on the same named profile is refused.

Gate on `command -v podman` + the image present; skip (not fail) otherwise. A profile
is seeded by a no-op launch (there is no `profiles new`); the EXIT trap force-removes
any container the run left (there is no `profiles gc`).

## Tier C — live agent persistence (gated, real model cost)

`tests/live-agent.sh` (`make test-live-agent`) drives a **real agent** to prove profile
persistence end to end, all through one config file (`profile.mode: profile`):

1. seed the profile with a no-op launch;
2. one-shot run 1 (`agentdev -c <cfg> --prompt <file>`) writes a secret into the
   profile's `.claude` home (memory) and leaves a session transcript (history);
3. hard-assert on the host that both persisted;
4. one-shot run 2 (fresh session, same profile) whose prompt can only succeed by reading
   the persisted secret — retried once, then fails.

Auth is subscription (`auth.mode: auto` inherits the host login; `ANTHROPIC_API_KEY`
deliberately unset). Gate on podman + image + a readable host login; skip otherwise.
Prompts go through `--prompt`, so there is no inline `-p` and no TTY-stdin hang; the EXIT
trap force-removes containers by label so a stall can never wedge podman.

## Integration & CI

`make test` (alias `make run-tests`) runs the offline suite (`smoke.sh` + `matrix.py`)
and needs no podman — the CI entrypoint. `make test-live` and `make test-live-agent` run
the gated live tiers. `make lint` syntax-checks the shell and Python and runs shellcheck
when present.

Note: Tier B surfaced and fixed a real product bug — `confirm_rw_mount` probed `/dev/tty`
by stat, which passes even with no controlling terminal; it now probes by opening the
device, so it fails closed correctly in CI/non-interactive runs.
