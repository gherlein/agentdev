# Testing plan

agentdev's correctness lives almost entirely in the **settled plan** — the `podman` command and
mount set that `--dry-run` produces with no container, no network, and no real credentials. So we
split testing into a cheap, near-exhaustive **offline tier** and small, gated **live tiers**.

Every launch is driven by a config file (the only CLI options are `-c`, `--dry-run`, `--prompt`,
and `-- command`), so each test writes a config and runs `agentdev -c <cfg> …`.

## The config surface

| Key | Values | Validity constraints |
|---|---|---|
| `image` | string | — |
| `workspace.source` / `mount` | dir / name | mount is one path segment; not a system name (`etc`, …) |
| `workspace.mode` | rw, ro | — |
| `workspace.ssh` / `usb` | true, false | — |
| `workspace.files` | `[{source,name}]` | each source is an existing file |
| `network.mode` | off, none, allowlist | allowlist ⇒ non-empty `allow` |
| `mounts.agent_folder` | path | — (omit ⇒ ephemeral home) |
| `mounts.read_only` / `read_write` | `[{src,dest}]` | src exists; dest absolute; targets unique |
| `mounts.history` / `memory` | path | agent must have a separable history/memory folder |
| `mounts.tty_devices` | `[/dev/ttyX]` | each matches `/dev/ttyX` and is a device node |
| `one-shot` | `{agent, model, prompt}` | agent ∈ {claude, omp, pi}; a one-shot run needs a prompt |

## Tier A — offline plan tests (the bulk)

`tests/smoke.sh` and `tests/matrix.py`, run by `make test` / `make run-tests`. Each case writes a
config and runs `agentdev -c <cfg> --dry-run` in a throwaway HOME + temp workspace. No containers,
no network, no real credentials, so it runs exhaustively in CI with no podman. We assert
**invariants** on the dry-run output (properties), not golden text.

- **`tests/smoke.sh`** — config resolution (`-c` / `$AGENTDEV_CONFIG` / `./default`, `-c`
  overriding the env, missing file, no config); **strict validation** (typo'd key, retired key,
  bad enum, missing workspace); removed-flag migration errors; interactive vs one-shot (and
  `--prompt` forcing one-shot); and the `jsoncfg.py` verbs (`get`/`has`/`rows`/`validate`).
- **`tests/matrix.py`** — the permutation matrix:
  - **G1** interactive vs one-shot (each agent's run mode, prompt mount, headless command, model env).
  - **G2** workspace (mount name → `/name` + `-w`, default basename, `mode: ro`, `ssh`/`usb` off,
    `workspace.files` injection).
  - **G3** mounts (`agent_folder` home + `--name`/label, ephemeral when omitted, `read_only`/
    `read_write` pairs, claude history+memory redirects, omp memory redirect, tty device).
  - **G4** network (off / none / allowlist + proxy env).
  - **G5** negatives (fail closed).

### Negative suite (must exit non-zero with a specific message)

Unknown key, retired key (`profile`, `auth`, …), bad enum, a `read_only` given as a map instead of
a `{src,dest}` list, a non-`/dev/ttyX` device, `pi` + `mounts.memory` (no separable memory),
`omp` + `mounts.history` (history is a DB), a one-shot run with no prompt, a mount name with a
slash, a system-path mount name (`etc`), and a missing mount source.

## Tier B — live behavioral tests (small, gated)

`tests/live.sh` (`make test-live`) launches real containers and asserts enforcement, not just the
plan. Each probe runs `agentdev -c <cfg> -- bash -lc '<probe>'` with a per-case config (built by
the `adev` helper). Checks:

- **ro workspace** → `touch /ws/x` fails; rw → succeeds.
- **`workspace.ssh: false`** → `/home/developer/.ssh` absent.
- **`read_write` pair** → the mounted dir is writable inside.
- **agent home** → a file placed in `agent_folder/.claude` is visible at `/home/developer/.claude`.
- **single-instance** → a second run on the same `mounts.agent_folder` is refused.
- **network none** → `curl` fails; **allowlist** → a denied host is blocked (and an allowed host
  reachable where the environment has upstream egress).

Gate on `command -v podman` + the image present; skip (not fail) otherwise. The EXIT trap
force-removes any container the run left (labelled `agentdev.home` / `agentdev.proxy`).

## Tier C — live agent persistence (gated, real model cost)

`tests/live-agent.sh` (`make test-live-agent`) drives a **real agent** to prove agent-home
persistence end to end, all through one config file (`mounts.agent_folder` set):

1. seed the home with a no-op launch;
2. one-shot run 1 (`agentdev -c <cfg> --prompt <file>`) writes a secret into the home and leaves a
   session transcript (history);
3. hard-assert on the host that both persisted into the `agent_folder`;
4. one-shot run 2 (fresh session, same home) whose prompt can only succeed by reading the persisted
   secret — retried once, then fails.

Auth is an API key: `ANTHROPIC_API_KEY` (from the host env) is written into a `.env` in the
workspace, which the one-shot run loads. Gate on podman + image + `ANTHROPIC_API_KEY`; skip
otherwise. Prompts go through `--prompt`, so there is no inline `-p` and no TTY-stdin hang.

## Integration & CI

`make test` (alias `make run-tests`) runs the offline suite (`smoke.sh` + `matrix.py`) and needs no
podman — the CI entrypoint. `make test-live` and `make test-live-agent` run the gated live tiers.
`make lint` syntax-checks the shell and Python and runs shellcheck when present.
