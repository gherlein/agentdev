# agentdev — Vision

> An isolated, containerized environment for running coding agents where **one JSON config
> file defines the entire launch**, and where the agent's on-disk state is nothing more than
> **host folders you mount in** — yours to seed, keep, wipe, or analyze with ordinary tools.
> Run it as an **interactive** shell you drive yourself, or add a **one-shot** block and let
> agentdev run the agent headless on a prompt and exit.

**The design goal, in one line:** reading the config file tells you exactly what the container
gets — the workspace, the network reach, the folders mounted in, and (for a headless run) the
agent and model. Nothing important comes from outside the file, and nothing in the file is
silently ignored.

**Claude Code is the primary agent; `omp` (oh-my-pi) and `pi` also ship.** agentdev is
agent-agnostic by design — the home is just "the home dir(s) for *this* agent."

---

## 1. Why this exists

`localdev` already gives us a safe container for running Claude Code in
`--dangerously-skip-permissions` mode without exposing the host filesystem. It works well, but
it bind-mounts the host's **real** `~/.claude` into the container: the agent *is* you. That is
right for "I am me, working on my project," and wrong for several things we increasingly want:

- **A true clean room** — run a task as a brand-new user with no history, no memory, no
  credentials, whose entire footprint you control.
- **Isolated, swappable state** — keep the agent's home as folders you can name, fork, archive,
  wipe, or version yourself, without entangling your daily-driver `~/.claude`.
- **A single source of truth** — one config file declares the whole run, so launching the same
  task twice, or handing it to a teammate, starts identically.
- **Safety end to end** — isolate the agent's home *and* lock down the network it can reach.

`agentdev` is **built fresh and stands alone**: its own container image, entrypoint, and mount
library, depending on nothing but `podman` and `python3`. It adopts the hardening localdev
proved out — a non-root user, `--userns=keep-id` ownership mapping, external mounts, TLS trust
and SSH-agent passthrough — and implements all of it itself.

---

## 2. Two ways to run: interactive or one-shot

A run is **interactive** by default: agentdev builds the container and drops you into a shell,
where you run the agent (`claude`, `omp`, `pi`) and pick the model yourself.

Add a **`one-shot`** block and agentdev runs the agent itself, headless, on a prompt file, then
exits. The **agent** and **model** live only in `one-shot`, because that is the only mode where
agentdev launches the agent — in interactive mode the human is in control.

That split is the spine of the design. Everything else — workspace, network, mounts — is shared
setup that applies either way.

---

## 3. The home is just folders you mount

Everything a coding agent keeps lives under a well-known home: `~/.claude` (+ `~/.claude.json`),
`~/.omp`, `~/.pi`. agentdev never bind-mounts your *real* home. Instead:

- **Clean room** — mount **empty** folders (or mount nothing): history and memory start fresh
  and the container's own copies are discarded on exit.
- **Persist** — point `mounts.agent_folder` at a host directory you keep, and the agent's home
  lives there across runs. It is a **plain folder you own** — `cp` to fork, `tar` to move, `git`
  to version, `rm` to wipe. agentdev runs no version control and offers no management
  subcommands.
- **Split history and memory out** — optionally set `mounts.history` and/or `mounts.memory` to
  separate host folders. agentdev knows the exact place each belongs under that agent's home and
  mounts it there. This lets you reuse one `agent_folder` for config while keeping *each run's*
  history or memory in its own folder for later analysis. Omit them and that data stays in
  `agent_folder`, or — if `agent_folder` is omitted too — on the ephemeral container filesystem,
  lost on exit.

Because the container workspace is a fixed, single-segment path, the per-agent location of
history and memory is deterministic, so agentdev can mount a host folder at exactly the right
place inside an otherwise-fresh home.

---

## 4. Environment and credentials come from a file, not the config

**agentdev forwards no credentials through the config.** Everything the agent needs —
`ANTHROPIC_API_KEY`, `AWS_*`, a gateway `ANTHROPIC_BASE_URL`, `CLAUDE_CODE_USE_BEDROCK`, and any
other model routing — comes from a **`.env` or `.envrc` in the workspace launch folder**. An
interactive shell loads it via `direnv`; a one-shot run sources it before invoking the agent.

This keeps secrets in the environment, where they belong, and out of a committed config file.
When the secret file should not live in the project tree, inject it with `workspace.files`,
which bind-mounts a host file into the working directory under a name you choose — so a `.env`
from a private host location appears in the workspace without ever being part of the repo. There
are no `auth`, `pass_env`, or `provider` keys.

---

## 5. Network and egress isolation

The container's network reach is set by `network.mode`:

- **`off` (default)** — ordinary networking; the whole internet is reachable.
- **`none`** — no network at all.
- **`allowlist`** — only an allowlist of destinations is reachable, via a filtering proxy sidecar
  on an internal (no-egress) network; everything else is refused. Domain-level by default, with
  an opt-in per-URL MITM tier (`network.mitm`). When `network.log` is set, every egress attempt
  is recorded for an auditable answer to "where did this agent talk to?"

Because model routing lives in `.env`, agentdev does not derive the model endpoint itself: under
`allowlist` you add your model's host (e.g. `api.anthropic.com`) to `network.allow`. For an
untrusted task, combine `allowlist` with a read-only workspace (`workspace.mode: "ro"`) and no
SSH (`workspace.ssh: false`).

---

## 6. Agents: Claude first, then the rest

`one-shot.agent` is a **short name** — `claude`, `omp`, or `pi` — that agentdev maps to the
executable inside the container. You never write a container path. The agents differ in how they
store state, so which of `mounts.history` / `mounts.memory` applies varies: Claude has both as
separable folders (`projects/<workspace>/` and `…/memory/`); `omp` has a separable memory folder
(`agent/memories/`) but its history is a database; `pi` has separable history (`agent/sessions/`)
but no memory store. Setting a redirect an agent doesn't support aborts. All three read their
credentials from the same `.env`/`.envrc` mechanism.

The image also ships the [herdr](https://herdr.dev) orchestrator, which is not a coding agent.

The abstraction generalizes because every agent keeps state under a well-known home. Admitting a
new agent is a per-agent table entry — its executable name, its home dir(s), where history and
memory live under that home, its model environment variable, and its headless-prompt command.
Nothing in the mount plan, the config schema, or the lifecycle changes shape.

---

## 7. Configuration: one file defines the launch

Everything is one JSON file. **Reading it tells you the whole run.**

### Where the file comes from

1. **`-c` / `--config <path>`** on the command line.
2. else **`$AGENTDEV_CONFIG`** from the environment.
3. else **`./agentdev-config.json`** in the current directory.

If none exists, agentdev refuses to launch. There is **no user-config layer** and **no
environment-variable mount input**: a key the file omits takes its built-in default, and nothing
else. Relative paths resolve against the **directory that holds the file**.

### The command line is tiny

- **`--dry-run`** — print the settled plan and the exact `podman` command; launch nothing.
- **`-c` / `--config <path>`** — select the config file.
- **`--prompt <file>`** — run one-shot on this prompt file (sets/overrides `one-shot.prompt`).
- **`-- COMMAND…`** — run a command instead of the interactive shell.

There are no other flags and no subcommands. The image is built out of band (`make build`).

### Strict, fail-closed

The file is validated against a schema before any key is read. An **unknown or misspelled key, a
wrong type, or a value outside its allowed set aborts the launch** and names the offending key. A
security setting can never be silently disabled by a typo. Keys beginning with `//` are comments.

### The shape

```jsonc
{
  "image": "ghcr.io/gherlein/agentdev:latest",

  "workspace": {
    "source": ".",            // host folder mounted at /<mount>
    "mount":  "work",         // its name in the container (default: basename of source)
    "mode":   "rw",           // rw | ro
    "ssh":    true,           // host ~/.ssh + agent socket
    "usb":    true,           // /dev/bus/usb
    "files": [ { "source": "~/vault/prod.env", "name": ".env" } ]   // host files bind-mounted into the working dir, read-only
  },

  "network": { "mode": "off", "allow": [], "log": false, "mitm": false },

  "mounts": {
    "agent_folder": "~/.agentdev/homes/myproject",                  // host dir mounted as the agent's home (omit = ephemeral)
    "read_only":  [ { "src": "~/ref", "dest": "/ref" } ],           // { src, dest } folder pairs
    "read_write": [ { "src": "~/out", "dest": "/out" } ],
    "history": "~/.agentdev/myproject/history",                     // optional: redirect this run's history to a separate host folder
    "memory":  "~/.agentdev/myproject/memory",                     // optional: redirect this run's memory
    "tty_devices": ["/dev/ttyUSB0"]                                 // serial/tty devices (/dev/ttyX)
  },

  // Omit for an interactive shell; include to run the agent headless, then exit:
  "one-shot": {
    "agent":  "claude",       // claude | omp | pi (mapped to the in-container executable)
    "model":  "claude-opus-5-5",
    "prompt": "task.md"
  }
}
```

---

## 8. Requirements summary

### Functional
- F1. Launch a container with a workspace folder (`workspace.source`) mounted at `/<mount>`
  (default basename), read-write or read-only.
- F2. **Interactive by default** — a shell in which the human runs the agent.
- F3. **One-shot** (`one-shot` present) — agentdev runs the named agent headless on a prompt,
  then exits.
- F4. Mount a host directory as the agent's home (`mounts.agent_folder`); omit for an ephemeral
  home discarded on exit.
- F5. Optionally redirect this run's **history** and/or **memory** to separate host folders
  (`mounts.history` / `mounts.memory`), mounted at the agent-specific location agentdev knows.
- F6. **One JSON config file declares the whole launch**, validated **fail-closed** (unknown keys
  and invalid values abort before the container starts).
- F7. **Select the agent and model** in `one-shot`: `agent` (a short name mapped to the
  executable) and `model` (a name); all other model routing comes from `.env`/`.envrc`.
- F8. **Mounts:** `read_only` / `read_write` as `{ src, dest }` folder-pair arrays, and
  `tty_devices` as a list of `/dev/ttyX` nodes.
- F9. **Workspace file injection:** `workspace.files` bind-mounts host files read-only into the
  working directory under chosen names (e.g. a `.env`).
- F10. **Environment/credentials from `.env`/`.envrc`** in the workspace launch folder; no `auth`
  or credential keys in the config.
- F11. **Network:** `off` (default) | `none` | `allowlist` with egress logging and an optional
  per-URL MITM tier.
- F12. **Minimal CLI:** `--dry-run`, `-c`/`--config`, `--prompt`, `-- COMMAND`;
  `-c`/`$AGENTDEV_CONFIG`/`./agentdev-config.json` selects the file.
- F13. Provide, in agentdev's own image and launcher, the configured mounts, SSH forwarding, TLS
  passthrough, USB/tty passthrough, and UID/GID ownership mapping.

### Non-functional
- N1. **Isolation:** a clean run (no `agent_folder`, or empty folders) is provably free of prior
  history/memory/credentials and cannot mutate the host's real `~/.claude`; `allowlist` + a
  read-only workspace make a run safe even for untrusted prompts.
- N2. **Host-owned files:** rootless podman + `--userns=keep-id` means every file the agent
  writes into a mounted folder is owned by you, not root — the linchpin of the plain-folder model.
- N3. **Portability:** every mounted folder is a plain host directory you can archive, move,
  fork, or version yourself.
- N4. **Fail-closed config:** any unknown key, wrong type, or invalid value aborts before launch.
- N5. **Secret-safe:** credentials live in `.env`/`.envrc`, never in the config; a secret file
  can be injected from outside the repo via `workspace.files`.

### Non-goals (deliberately out of scope)
- Not a replacement for localdev's "I am me" workflow.
- **No CLI beyond `--dry-run`, `-c`/`--config`, `--prompt`, `-- COMMAND`, and no management
  subcommands** — mounted folders are plain directories you manage yourself.
- **No profile/modes machinery, no template auto-seeding, no workspace copy-on-write, no
  overlay/immutable templates, no fleet / best-of-N, no cost accounting.** These were considered
  and cut; ordinary files, `.env`, mounts, git, and a shell cover them.
- Not a secrets manager; it loads `.env`/`.envrc` and injects files, nothing fancier.

---

## 9. Roadmap: Claude first, then the rest

- **Now — Claude fully wired**, plus `omp` and `pi` present in the image and selectable by name.
  Interactive and one-shot runs; the mounted-home model with optional history/memory redirects;
  `.env`/`.envrc` credentials; network `off` / `none` / `allowlist` with egress logging; a single
  strict, fail-closed config file; `--dry-run`.
- **Next — deepen `omp` and `pi`**: complete their per-agent tables (headless-prompt command,
  model environment, and history/memory redirect targets) so one-shot is as solid for them as for
  Claude.

The north star stays fixed: **the agent's entire self — what it was told, everything it
remembers, and everything it did — is just folders you mount and control, and one config file
defines exactly how it runs.**
