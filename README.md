# agentdev

Run a coding agent in an isolated container where **one JSON config file defines the entire
launch**. By default a run is **interactive** — agentdev drops you into a shell and *you* run
the agent (`claude`, `omp`, `pi` supported out of the box). Add a **`one-shot`** block to the config and agentdev runs the
agent itself, headless, on a prompt, then exits.

The agent's **home** is just host folders you mount in (`mounts.agent_folder` and
`mounts.read_write`) — never your real `~/.claude` unless you point it there. For a **clean
room**, mount **empty** folders so history starts fresh; to **persist** what the agent learned
and did across runs, add its **memory** folder and its **project (transcript)** folders to
`mounts.read_write`. They're plain directories you own — `cp`, `rm`, `tar`, `git` them — and
agentdev never versions them or hides them behind management subcommands. We ship example
configs for the common setups.

> **Claude Code is the primary agent; `omp` (oh-my-pi) and `pi` also ship.** agentdev is
> agent-agnostic by design — the home is just "the home dir(s) for *this* agent." See
> [`VISION.md`](./VISION.md) and [`DESIGN.md`](./DESIGN.md).

agentdev is **self-contained**: it ships its own container image, entrypoint, and mount
library, and depends on nothing but `podman` and `python3`.

## Prerequisites

- **Linux** with **rootless [podman](https://podman.io)** — the reason it must be podman is below.
- **python3** — the launcher parses the JSON config with it (already a Claude Code prerequisite).
- **The container image** — pulled from ghcr.io on first launch, or built locally with `make build`.
- **Credentials in your environment** — the agent reads `ANTHROPIC_API_KEY` (and any model
  routing) from a `.env`/`.envrc` in the workspace; agentdev passes none through its config.

### Why podman (and why rootless)

agentdev's core promise is that the agent's home and your workspace are **plain folders you
own** — seed, `cp`, `git`, or `rm` them with no special tooling. That only holds if the files
the agent writes come out owned by *you*, not `root`. Rootless podman is what delivers it:

- **No root daemon.** Containers run as your user; nothing privileged runs on the host.
- **`--userns=keep-id` maps the container user to your host UID**, so every file written into
  the mounted home and the workspace is host-owned. This is the linchpin of the whole
  plain-folder model and of the clean-room ownership guarantees.

A rootful Docker daemon runs as root and writes **root-owned** files into those folders, which
breaks that model — so podman rootless is a hard requirement today. (Rootless Docker preserves
the same ownership model and could be supported later; rootful Docker can't be, without
`--user` entrypoint surgery.)

## Install

See [Prerequisites](#prerequisites) for requirements (Linux + rootless podman).

### Install from Homebrew

```bash
brew tap gherlein/tap
brew trust gherlein/tap          # a tap must be trusted before its formulae load
brew install agentdev
```

Homebrew installs the launcher and `podman`; the container image is pulled from ghcr.io on
first launch. Upgrade/remove with `brew upgrade agentdev` / `brew uninstall agentdev`.

### Install from the repo

```bash
git clone https://github.com/gherlein/agentdev ~/src/agentdev && cd ~/src/agentdev
make build                       # build the container image once
make install                     # symlink the launcher into ~/.local/bin
```

`make install` **symlinks** the launcher (it sources `lib/`, `templates/`, and `image/` from
the checkout), so edits and `git pull` take effect immediately. `make` with no target lists
every target; `make uninstall` removes the symlink.

## Run it

```bash
cd ~/src/my-project
cp -r ~/src/agentdev/templates/claude ./agentdev && cp agentdev/agentdev-config.json .
<edit config>
agentdev --dry-run          # print the settled plan 
agentdev                    # no one-shot block -> a shell; run `claude` inside
```

The command line is tiny — the config file carries everything:

| Flag | Effect |
|---|---|
| `-c`, `--config <path>` | optionally select the config file (else `$AGENTDEV_CONFIG`, else `./agentdev-config.json`) |
| `--dry-run` | print the settled plan and the `podman` command, then exit — launch nothing |
| `--prompt <file>` | run one-shot on this prompt file (sets/overrides `one-shot.prompt`) |

(Append `-- COMMAND` to run a command instead of the interactive shell.)

## Configuration

One JSON file is the whole truth. It's validated **fail-closed** — an unknown key, wrong
type, or bad value aborts before the container starts and names the offender. Relative paths
resolve against the **config file's directory**. Keys beginning with `//` are comments.

A config declares the shared container setup. By default that's an **interactive** run — you
get a shell and run the agent yourself. Add a `one-shot` block to make agentdev run the agent
itself, headless, then exit. Here's a whole file; each block is explained below it.

```jsonc
{
  "image": "ghcr.io/gherlein/agentdev:latest",   // container image (pin by digest for reproducibility)

  "workspace": {
    "source": ".",                 // host folder to mount
    "mount":  "work",              // its name in the container -> /work   (default: basename of source)
    "mode":   "rw",                // rw | ro
    "ssh":    true,                // mount host ~/.ssh + forward the agent socket
    "usb":    true,                // pass /dev/bus/usb
    "files": [                     // host files dropped INTO the working folder, read-only, by a chosen name
      { "source": "~/vault/prod.env", "name": ".env" }
    ]
  },

  "network": { "mode": "off", "allow": [], "log": false, "mitm": false },  // off | none | allowlist

  "mounts": {
    "agent_folder": "~/.agentdev/homes/myproject",                        // host dir mounted as the agent's home (omit = ephemeral)
    "read_only":  [ { "src": "~/ref/standards", "dest": "/standards" } ], // folder pairs, bind-mounted read-only
    "read_write": [ { "src": "~/out/shared",    "dest": "/shared" } ],    // folder pairs, bind-mounted read-write
    "history": "~/.agentdev/myproj/history",                              // optional: send THIS session's history to a separate host folder (agentdev knows where it lands in the home)
    "memory":  "~/.agentdev/myproj/memory",                              // optional: send THIS session's memory to a separate host folder
    "tty_devices": ["/dev/ttyUSB0"]                                       // serial/tty devices to pass through (/dev/ttyX)
  },

  "skills": {                                                             // a read-only bundle from the shared store (omit for none)
    "store":   "~/.local/share/skills",                                  // the shared, flat skills store (default: XDG data home)
    "profile": "backend",                                                // a named bundle: $XDG_CONFIG_HOME/agentdev/profiles/backend
    "include": ["git-ops", "documentation"]                              // extra skills by name (composes with the profile)
  },

  "mcp": ["~/.config/agentdev/mcp/codebase-memory.json"],                 // a strict allowlist of MCP config files (omit to inherit the home; [] = no servers)

  // Omit "one-shot" for an interactive shell; include it to run the agent headless, then exit:
  "one-shot": {
    "agent":  "claude",                              // supported agent: claude | pi | omp (agentdev maps it to the in-container executable)
    "model":  "claude-opus-5-5",                     // model name (optional; agent default if omitted)
    "prompt": "task.md"                              // the prompt file
  }
}
```

Every key is optional and takes a built-in default; omit a whole block to accept its defaults.

### workspace — the project folder, named, plus injected files

- `source` — the host folder to mount; it appears at `/<mount>` and the agent starts there.
- `mount` — the container-side name for that folder (default: the source's basename).
- `mode` — `rw` or `ro`.
- `ssh` — passes your host `~/.ssh` keys and the agent socket into the container.
- `usb` — passes `/dev/bus/usb` into the container.
- `files` — each `{source, name}` bind-mounts a host file into the working directory, read-only,
  under a name you choose, so you can **inject a `.env` or `.envrc` from anywhere on the host
  without it ever living in the project tree**.

### Environment & credentials

**agentdev forwards no credentials through the config.**

- Everything the agent needs — `ANTHROPIC_API_KEY`, `AWS_*`, a gateway `ANTHROPIC_BASE_URL`,
  `CLAUDE_CODE_USE_BEDROCK`, model routing — comes from a **`.env` or `.envrc` in the workspace
  launch folder**.
- An interactive shell loads it via `direnv`; a one-shot run sources it before invoking the agent.
- Inject that file with `workspace.files` to keep secrets out of your repo.
- There are no `auth`, `pass_env`, or `provider` keys in the config.

### network

- `off` — full internet (the default).
- `none` — no network at all.
- `allowlist` — only `network.allow` destinations are reachable, via a filtering proxy sidecar,
  with optional egress `log` and per-URL `mitm`; add your model's host (e.g. `api.anthropic.com`)
  to `allow`.

### mounts — agent home, folders, copied files, tty devices

- `agent_folder` — a host directory bind-mounted as the agent's home (its `.claude` / `.omp` /
  `.pi`), holding its config and, by default, its history and memory too. Omit it for an
  ephemeral home discarded on exit; point it at a kept folder to persist across runs. You manage
  that folder yourself (`cp`, `git`, `rm`).
- `read_only` / `read_write` — arrays of `{ src, dest }` pairs that bind host **folders** at
  arbitrary container paths.
- `history` / `memory` — optional host folders (one path each). Set one only when you want **this
  session's** history or memory written to a *separate* folder instead of inside `agent_folder` —
  e.g. reuse one `agent_folder` for config across runs, but split each run's history/memory out
  for later analysis. **You give the host folder; agentdev knows the exact place it belongs under
  the agent's home and mounts it there.** Omit them and history/memory stay in `agent_folder` (or,
  if that's omitted too, on the ephemeral container filesystem — lost on exit).
- `tty_devices` — an array of serial/tty devices to pass through; each must be a `/dev/ttyX`.

### skills — a read-only bundle from the shared store

- One shared, agent-neutral **store** holds every skill, flat, one directory per skill
  (the [Skill Embedding Standard](https://github.com/gherlein/skill-embedding-standard)).
  `store` defaults to `$XDG_DATA_HOME/skills` (`~/.local/share/skills`).
- `profile` names a **bundle**: a file at `$XDG_CONFIG_HOME/agentdev/profiles/<name>` listing
  skill names one per line (`#` comments and blank lines ignored).
- `include` adds skills by name inline; it composes with `profile` (deduplicated).
- agentdev copies the selected skills into the agent's `.claude/skills` and mounts them
  **read-only** — the agent reads them but cannot modify them. It is **one mount regardless of
  skill count**, recomputed from the config on every launch, so nothing persists or drifts.
- A persistent home's hand-placed skills are kept and **win** a name collision; a requested name
  that is not a conforming skill in the store aborts the launch (fail-closed).
- Read-only is a bind mount, not file permissions, because the agent can reach container-root and
  would otherwise be able to rewrite its own skills — see
  [`docs/containment-testing.md`](./docs/containment-testing.md).

### mcp — a strict allowlist of MCP config files

Control exactly which MCP servers an agent may use. `mcp` is an array of paths to MCP config files
on the host — ordinary files in the shape Claude accepts for `--mcp-config` / `.mcp.json`:

```json
{ "mcpServers": { "codebase-memory": { "command": "codebase-memory-mcp", "args": ["--serve"] } } }
```

- agentdev copies the listed files into a per-run staging dir mounted **read-only** at
  `/home/developer/.agentdev-mcp` (one mount regardless of count) and wires the agent to load them.
- **One-shot runs enforce it as a true allowlist:** the headless `claude` command is launched with
  `--strict-mcp-config --mcp-config …`, so the agent loads **only** these servers and ignores every
  other scope (the mounted home's `.claude.json`, the workspace `.mcp.json`, user scope).
- **`mcp` is claude-only.** A one-shot run with `omp`/`pi` and an `mcp` block aborts (those agents
  have no `--mcp-config` surface).
- **Presence matters:** omit `mcp` to inherit whatever the mounted home provides (default); `"mcp": []`
  is a deliberate **deny-all** (strict with zero servers — a hardened, MCP-free run); a non-empty list
  is the allowlist.
- **Interactive runs are advisory.** agentdev launches only a shell, so it cannot force a flag onto the
  `claude` you type. The files are still staged read-only and the ready-made flags are exported as
  `$AGENTDEV_MCP_ARGS`; the real backstop for remote servers is [`network`](#network).
- **Keep secrets out of the files:** use `${VAR}` references (Claude expands them from the run's env,
  which a one-shot already loads from the workspace `.env`), so the files stay commit-safe. agentdev
  never logs file contents. A missing or malformed file (no top-level `mcpServers`) aborts the launch.
- Read-only is a bind mount, not file permissions, for the same containment reason as `skills`.

### one-shot — run the agent headless (optional, last because it's the exception)

**Omit this block for an interactive shell.** Include it and agentdev runs the agent itself on
the prompt, then exits.

- `agent` — a **supported-agent name** (`claude`, `pi`, `omp`) that agentdev maps to the
  executable inside the container; you never write a container path.
- `model` — the model name (optional; the agent's default if omitted).
- `prompt` — the prompt file; `--prompt <file>` sets or overrides it from the CLI.

`agent` and `model` live here because this is the only mode where agentdev launches the agent
itself — in an interactive run you pick them inside the shell.

## Supported agents

In `one-shot`, `agent` is a **short name** from the set below and agentdev maps it to the
executable inside the container — you never write a container path. They store state differently,
so which of `mounts.history` / `mounts.memory` applies varies by agent. (The image also ships the
[herdr](https://herdr.dev) orchestrator, which is not a coding agent.)

| `one-shot.agent` | Agent | Home | `mounts.memory`? | `mounts.history`? |
|---|---|---|---|---|
| `claude` | Claude Code | `~/.claude` + `~/.claude.json` | **yes** — `projects/<ws>/memory/` | **yes** — `projects/<ws>/` |
| `omp` | oh-my-pi | `~/.omp` | **yes** — `agent/memories/` | **no** — history is a DB |
| `pi` | pi | `~/.pi` | **no** — no memory store | **yes** — `agent/sessions/` |

Setting a redirect an agent doesn't support aborts with a clear message.

Every agent's credentials come from the same `.env`/`.envrc` mechanism.

## templates/<agent> — per-agent starter kits

Copy-by-hand starting points, one folder per supported agent:

```
templates/
├── claude/   # agentdev-config.json, CLAUDE.md, settings.json, env.example
├── omp/      # agentdev-config.json, AGENTS.md, env.example
└── pi/       # agentdev-config.json, AGENTS.md, env.example
```

```bash
cp -r ~/src/agentdev/templates/claude ./agentdev   # then edit for your project
```

These are plain files you edit — not an auto-seeding mechanism. (`cp env.example` somewhere
private, then inject it as `.env` via `workspace.files`.)

## What isolation does and doesn't cover

The mounted home isolates the agent's **on-disk state**. It does **not** isolate your
**claude.ai account**: if you log the agent into a subscription, account-level **connectors**
(Atlassian, Microsoft 365, Slack, …) appear even in a clean room — they follow the login, not
the mounted home.
To keep a run connector-free, authenticate with an API key via `.env` (no subscription login).
See [`docs/managing-context-and-memory.md`](./docs/managing-context-and-memory.md).

## Locked-down runs

For an untrusted task, combine `network.mode: "allowlist"` (+ egress `log`), a read-only
workspace (`workspace.mode: "ro"`), and no SSH (`workspace.ssh: false`). The egress log is
written into the agent home, so set `mounts.agent_folder` to keep it; then read it with ordinary
tools:

```bash
cut -f2,4 <agent_folder>/agentdev-egress.log | sort | uniq -c | sort -rn
```

For fanning prompts across many tasks in parallel, see
[`examples/one-shot-orchestrator/`](./examples/one-shot-orchestrator/).

To verify the containment actually holds — a real authenticated agent is told to break out and
proven host-side that it cannot — run `make test-live-containment`; the method is documented in
[`docs/containment-testing.md`](./docs/containment-testing.md).

## Layout

```
agentdev              launcher (bash)
lib/                  config, agents, mounts, net (+ jsoncfg.py — the strict schema/reader)
image/                Containerfile + entrypoint.sh + proxy.py (egress allowlist sidecar) -> ghcr.io/gherlein/agentdev
templates/<agent>/    per-agent starter kits (copy and edit)
examples/             worked config scenarios and the one-shot orchestrator
tests/                offline smoke + matrix, live tiers, proxy unit tests
```

## Status

**Implemented:** interactive by default with an optional `one-shot` block; `agent` as a **short
name** (`claude`/`omp`/`pi`) agentdev maps to an executable; credentials and model routing via
`.env`/`.envrc`; `workspace` with `mount` name, `mode`, `ssh`/`usb`, and injected `files`; `mounts`
with `agent_folder`, `read_only`/`read_write` pairs, optional `history`/`memory` redirects, and
`tty_devices`; `omp` and `pi` as additional agents; `templates/<agent>/` starter kits. The launcher
and `lib/` parse this schema; retired keys (`profile`, `auth`, `template`, `sandbox`, `agent`/`model`
objects, `mounts.devices`, …) are rejected fail-closed with migration hints. opencode removed.

**Next:** deepen `omp` and `pi` — their headless-prompt command and model environment are
best-effort today; Claude is fully wired.

**Deliberately out of scope:** workspace copy-on-write / patch-review, overlay/immutable
templates, fleet / fan-out, cost accounting, and any profile/memory management subcommands —
see [`VISION.md`](./VISION.md).

## Containment, verified

The containment is not just asserted — it is tested adversarially. `make test-live-containment`
(Tier D) boots a **real agent from a copy of your own `~/.claude` credentials** (the live
directory is never touched), tells it to **break out of the container**, and then proves
**host-side** that it could not. The verdict comes from agent-free scripted probes and planted
host canaries, not the agent's self-report, so a lazy or refusing agent cannot produce a false
"all clear."

Latest run: **13 held, 0 breached, 0 skipped.** An authenticated agent, actively trying to
escape, could not:

- read a host file outside its mounts, or write anything outside its sandbox;
- modify a `read_only` mount;
- gain host privilege — in-container root maps to an unprivileged host user via `--userns=keep-id`, and host root-only files stay unreadable;
- nest a container — an unprivileged nested run fails at user-namespace setup, and `/dev/fuse` is absent;
- see the host's processes — the container has its own PID namespace;
- reach a device not listed in `tty_devices`;
- exfiltrate over the network — `network.mode: none` blocks all egress, and `allowlist` blocks any host you did not permit.

`network.mode: off` is host networking by design (egress open) and is **not** a containment
boundary; locked-down runs use `none` or `allowlist`. The full method — the trust model, the
rootless-podman subtleties, and how to run and read it — is in
[`docs/containment-testing.md`](./docs/containment-testing.md).
