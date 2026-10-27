# agentdev — Technical Design

> Companion to [`VISION.md`](./VISION.md) and [`README.md`](./README.md). This document
> specifies the implementation: the component breakdown, the one config file and its schema,
> the agent table, and the mount algorithm. It describes the code as it stands.
>
> **One config file defines the launch.** A run is **interactive** by default; adding a
> `one-shot` block makes agentdev run the named agent headless on a prompt and exit. The agent's
> on-disk state is just **host folders you mount** (`mounts.agent_folder`, with optional
> `mounts.history` / `mounts.memory` redirects). Credentials come from a `.env`/`.envrc` in the
> workspace, never the config. The CLI is `--dry-run`, `-c`, `--prompt`, and `-- command`.

**agentdev is self-contained.** It ships its own container image, entrypoint, and mount library,
and depends only on `podman` and `python3`. It adopts localdev's hardening (non-root user,
`--userns=keep-id`, external mounts, TLS/SSH passthrough) and implements all of it itself, while
inverting the one choice that matters: the agent's home is a folder you mount, never the host's
real `~/.claude`.

---

## 1. Architecture overview

```
agentdev (this repo)
├── agentdev                  ← the launcher (bash); the only entry point
├── lib/
│   ├── config.sh             ← resolve + validate the one config file; settle every key
│   ├── jsoncfg.py            ← the strict schema + reader (get | list | rows | has | check | validate)
│   ├── agents.sh             ← the per-agent table (exec, home dirs, history/memory, model env, headless cmd)
│   ├── mounts.sh             ← build the podman mount plan (workspace, files, home, redirects, folders, tty)
│   └── net.sh                ← network modes + the egress proxy sidecar
├── image/
│   ├── Containerfile         ← builds ghcr.io/gherlein/agentdev (hardened, non-root; claude/omp/pi + herdr)
│   ├── entrypoint.sh         ← UID/GID remap, host-home symlink, CA rebuild, gosu exec
│   └── proxy.py              ← egress allowlist proxy, run as a sidecar from this image
├── templates/<agent>/        ← copy-by-hand starter kits (claude, omp, pi)
├── examples/                 ← worked config scenarios + the one-shot orchestrator
└── tests/                    ← offline smoke + matrix, live tiers, proxy unit tests
```

The launcher sources `config agents mounts net`. Shared state is a small set of globals the mount
plan and the podman assembly read. There are **no management subcommands**: the launcher only
launches (with `--dry-run` to preview).

### The image

Debian-slim, non-root `developer` user (UID 1000), `NOPASSWD` sudo for the entrypoint's privileged
steps. It carries the full localdev toolset plus the **Claude Code CLI**, **omp** (oh-my-pi),
**pi** (`@mariozechner/pi-coding-agent`), and the **[herdr](https://herdr.dev)** orchestrator. The
image is pulled from ghcr.io on first launch; pin the `image` key by digest (`make digest`) for a
reproducible run.

### The entrypoint

Starting as root (under `--userns=keep-id` the mapped user): `usermod`/`groupmod` the `developer`
user to `$HOST_UID`/`$HOST_GID`, rename its login to `$HOST_USER`, point its home at `$HOST_HOME`,
create the **`$HOST_HOME → /home/developer` symlink** (so an absolute `$HOME` resolves), optionally
rebuild the CA trust bundle, then `exec gosu "$HOST_USER" "$@"`. The symlink is why the launcher can
mount the agent home at `/home/developer/.claude` while the agent still sees it at `$HOME/.claude`.

---

## 2. The config file

The sole format is one JSON file, chosen by `-c` → `$AGENTDEV_CONFIG` → `./agentdev-config.json`.
It is validated **fail-closed** by `jsoncfg.py validate` before any key is read: an unknown or
misspelled key, a wrong type, or a value outside its enum aborts and names the key. Keys beginning
with `//` are comments. Relative paths resolve against the config file's directory.

### Schema (`lib/jsoncfg.py`)

| Group | Keys | Notes |
|---|---|---|
| (top) | `image` | container image |
| `workspace` | `source` `mount` `mode` `ssh` `usb` `files` | `mode` ∈ {rw, ro}; `files` is a list of `{source, name}` |
| `network` | `mode` `allow` `log` `mitm` | `mode` ∈ {off, none, allowlist} |
| `mounts` | `agent_folder` `read_only` `read_write` `history` `memory` `tty_devices` | `read_only`/`read_write` are lists of `{src, dest}`; `tty_devices` each `/dev/ttyX` |
| `one-shot` | `agent` `model` `prompt` | `agent` ∈ {claude, omp, pi}; **absence of the whole block ⇒ interactive** |

`jsoncfg.py` leaf types: `str`, `bool`, enum tuples, `str-list`, `tty-list`, `pair-list`
(`{src,dest}`), `file-list` (`{source,name}`). Verbs: `get` (scalar), `list` (string list),
`rows <key> <field…>` (fields of a list-of-objects, tab-separated), `has` (key present?), `check`
(parses?), `validate` (matches schema?). A `RETIRED` table turns old keys (`profile`, `auth`,
`template`, `sandbox`, `agent`, `model`, `mounts.devices`, `workspace.workdir`, …) into pointed
migration errors.

---

## 3. The agent table (`lib/agents.sh`)

`one-shot.agent` is a short name mapped to everything agent-specific. Container home base is
`/home/developer` (the host-home symlink target).

| agent | home items | history dest | memory dest | model env | headless |
|---|---|---|---|---|---|
| `claude` | `.claude` (dir), `.claude.json` (file) | `…/.claude/projects/<ENC>` | `…/projects/<ENC>/memory` | `ANTHROPIC_MODEL` | `claude --dangerously-skip-permissions -p "$(cat …)" </dev/null` |
| `omp` | `.omp` (dir) | — (sqlite DB) | `…/.omp/agent/memories` | — | `omp -p …` (best-effort) |
| `pi` | `.pi` (dir) | `…/.pi/agent/sessions` | — (no memory store) | — | `pi -p …` (best-effort) |

`ENC = "-" + <mount>` with `.` → `-` (the container workspace is the single segment `/<mount>`, so
Claude's `projects/` directory name is deterministic). A `history`/`memory` redirect whose agent has
no separable location (e.g. `pi` + memory) aborts with a clear message. Claude is fully wired; `omp`
and `pi`'s headless command and model env are best-effort (VISION §9).

---

## 4. Control flow of one launch

```
agentdev [--dry-run] [-c <config>] [--prompt <file>] [-- command...]
  │
  ├─ resolve config path (-c > $AGENTDEV_CONFIG > ./agentdev-config.json); load_config: validate + settle
  ├─ resolve workspace.source; DIR_NAME = workspace.mount or basename; ENC = -<DIR_NAME>
  ├─ RUN_MODE = one-shot if (one-shot block present OR --prompt) else interactive
  │     one-shot: validate agent; resolve + mount the prompt ro; COMMAND = bash -lc "<load .env/.envrc>; <headless cmd>"
  │     interactive: COMMAND = bash (or the trailing -- command)
  ├─ if mounts.agent_folder:  flock it + assert no live container (single-instance) + fixed --name/label
  ├─ collect_mounts: workspace; workspace.files (ro); agent home from agent_folder; history/memory redirects;
  │                  read_only/read_write {src,dest}; tty_devices
  ├─ collect_ssh_mount (workspace.ssh); model env (one-shot + agent model env); userns; workspace.usb
  ├─ setup_network (off | none | allowlist + proxy; egress log into the agent home)
  ├─ assemble podman argv (net, userns, usb, devices, workspace, home, ssh, volumes, prompt, model, HOST_* env, -w /<mount>)
  │     --dry-run prints the settled plan + full podman command and EXITS here (no side effects)
  └─ podman run ... IMAGE  (bash by default, or the headless one-shot command)
     on exit (trap): teardown network; drop the temp mount-map file
```

An **ephemeral** run (no `agent_folder`) mounts no home, so the container's own `.claude` is created
and discarded with `--rm` — the clean room. A **persistent** run mounts `agent_folder`; `history`/
`memory` overlay host folders at the agent's known subpaths. Nothing is seeded: a fresh home starts
empty (agentdev pre-creates the empty, host-owned home dirs/files so podman has mount points).

---

## 5. The mount plan (`lib/mounts.sh`)

`collect_mounts DIR_NAME` builds four arrays — `WORKSPACE_MOUNT`, `HOME_MOUNTS`, `VOLUME_MOUNTS`,
`DEVICE_MOUNTS` — plus `MOUNTS_CONTENT` (the in-container `~/mounts` map), with one rule: every
container-side target is claimed once; a second claim on the same target is fatal (`register_target`).

- **workspace** — `WS_SOURCE:/<DIR_NAME>:<mode>`.
- **workspace.files** — each `{source, name}` is an existing host *file*, bound read-only at
  `/<DIR_NAME>/<name>` (the `.env` injection path).
- **agent home** — when `agent_folder` is set, each of the agent's home items is bound from
  `agent_folder/<item>` to `/home/developer/<item>` read-write, pre-created empty for a clean home.
- **history / memory** — the host folder is bound read-write at the agent's known destination
  (nested inside the `.claude` mount for Claude; that is a valid overlay). Unsupported for an agent
  without that separable folder → abort.
- **read_only / read_write** — `{src, dest}` pairs; `src` must be an existing directory, `dest` an
  absolute container path.
- **tty_devices** — each `/dev/ttyX`, verified to be a device node, passed with `--device`.

Source directories/files that are missing, not of the right type, or unreadable **abort the launch**
(fail-closed). `mkdir`/touch side effects are skipped under `--dry-run`.

---

## 6. Environment, credentials, and network

**Credentials never pass through the config.** The agent reads everything it needs
(`ANTHROPIC_API_KEY`, `AWS_*`, a gateway `ANTHROPIC_BASE_URL`, `CLAUDE_CODE_USE_BEDROCK`, …) from a
`.env` or `.envrc` in the workspace launch folder. An interactive shell loads it via the image's
`direnv` hook; a one-shot run's command sources it (direnv for `.envrc`, `set -a; . ./.env` for a bare
`.env`) before invoking the agent. A secret file that should stay out of the repo is injected via
`workspace.files`.

**Network** (`lib/net.sh`): `off` (host networking) · `none` (`--network none`) · `allowlist` (the
agent joins an `--internal` podman network; a proxy sidecar from the same image bridges it to a normal
network; `HTTP(S)_PROXY` points the agent at the proxy, so a client ignoring the proxy reaches
nothing). `network.log` writes `<agent_folder>/agentdev-egress.log` (ephemeral if no `agent_folder`);
`network.mitm` adds per-URL filtering with a per-run CA. Because model routing lives in `.env`,
agentdev does not derive the model endpoint — under `allowlist` you add the model host to
`network.allow`. The proxy and networks are removed by the EXIT trap.

---

## 7. Single-instance guard (persistent home)

A mounted `agent_folder` is a shared folder a run mutates live, so at most one run may hold it at a
time. The guard is layered: a `flock` on `<agent_folder>/.agentdev.lock-file` (serializes launchers;
the fd is closed in the podman child so a detached container cannot pin it), a live-container
assertion (`podman ps --filter label=agentdev.home=<path>`, catching an orphan whose launcher died),
and a fixed `--name` per folder (the runtime itself refuses a second `run`). Ephemeral runs need no
guard — each gets its own throwaway home.

---

## 8. Scope boundary

**In:** the self-contained image; the single strict fail-closed config file; the minimal CLI
(`--dry-run`, `-c`, `--prompt`, `-- command`); interactive and one-shot runs; the agent name→executable
map (claude fully wired, omp/pi present); mounted-home state with optional history/memory redirects;
`.env`/`.envrc` credentials; `workspace.files` injection; `read_only`/`read_write`/`tty_devices`
mounts; network `off`/`none`/`allowlist` with egress logging and an optional MITM tier; the
single-instance guard for a shared home.

**Deliberately out of scope** (cut, not deferred — ordinary files, `.env`, mounts, git, and a shell
cover them): profile/modes machinery, template auto-seeding, workspace copy-on-write / patch-review,
overlay/immutable templates, fleet / best-of-N, cost accounting, and any management subcommand.

**Next:** deepen `omp` and `pi` (their headless command, model env, and redirect targets) so one-shot
is as solid for them as for Claude.

---

*North star: the agent's entire self — what it was told, everything it remembers, and everything it
did — is just folders you mount and control, and one config file defines exactly how it runs.*
