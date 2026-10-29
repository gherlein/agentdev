# agentdev User Guide

agentdev runs a coding agent (Claude Code, `omp`, or `pi`) in an isolated container. **One JSON
config file defines the whole launch.** By default a run is **interactive** — you get a shell and
run the agent yourself; add a **`one-shot`** block to run the agent headless on a prompt and exit.
The agent's on-disk state is just **host folders you mount**, never your real `~/.claude`.

See [`README.md`](../README.md) for the quick tour, [`VISION.md`](../VISION.md) for the why, and
[`DESIGN.md`](../DESIGN.md) for the how.

## 1. What agentdev mounts

- **The workspace** (`workspace.source`, mounted at `/<mount>`) — the only project code the agent
  sees. The agent starts here.
- **The agent home** (`mounts.agent_folder`) — a host directory bound as the agent's home
  (`~/.claude` etc.). Omit it for an ephemeral home discarded on exit.

Everything else stays outside unless the config mounts it.

## 2. Install and build

### Requirements
**podman** (rootless), **python3**, and **Linux** (for `--userns=keep-id` ownership mapping).

### Install the launcher
```bash
git clone https://github.com/gherlein/agentdev ~/src/agentdev && cd ~/src/agentdev
make install                     # symlink the launcher onto your PATH (~/.local/bin)
```
`make install` symlinks the launcher (it sources `lib/`, `templates/`, `image/` from the checkout).
Or install a tagged release with Homebrew (`brew tap gherlein/tap && brew trust gherlein/tap &&
brew install agentdev`).

### Build the image
```bash
make build                       # build ghcr.io/gherlein/agentdev:latest
make digest                      # print the pin-by-digest ref for the `image` key
```
Re-run after changing anything under `image/`. A Homebrew install pulls the image from ghcr.io on
first launch instead.

## 3. The command line

The launcher reads a config file and launches the container. Its only options:

| Option | Effect |
|---|---|
| `-c`, `--config <path>` | select the config file |
| `--dry-run` | print the settled plan and the exact `podman` command; launch nothing |
| `--prompt <file>` | run one-shot on the prompt in `<file>` (sets/overrides `one-shot.prompt`) |
| `-- COMMAND...` | run COMMAND instead of the interactive shell |
| `-h`, `--help` | usage |

There are **no other flags and no subcommands**. The config path is resolved in order: `-c` →
`$AGENTDEV_CONFIG` → `./agentdev-config.json`; if none exists, agentdev refuses to launch.

```bash
cd ~/src/my-project
cp -r ~/src/agentdev/templates/claude ./agentdev && cp agentdev/agentdev-config.json .
agentdev --dry-run     # check the plan first
agentdev               # no one-shot block -> a shell; run `claude` inside
```

## 4. The config file

One JSON file is the whole truth. It is validated **fail-closed** before any key is read: an
unknown or misspelled key, a wrong type, or a value outside its allowed set aborts and names the
offending key. Keys beginning with `//` are comments. Relative paths resolve against the config
file's directory.

```jsonc
{
  "image": "ghcr.io/gherlein/agentdev:latest",

  "workspace": {
    "source": ".",            // host folder mounted at /<mount>
    "mount":  "work",         // its name in the container (default: basename of source)
    "mode":   "rw",           // rw | ro
    "ssh":    true,           // mount host ~/.ssh + forward the agent socket
    "usb":    true,           // pass /dev/bus/usb
    "files": [ { "source": "~/vault/prod.env", "name": ".env" } ]   // host files bound read-only into the working dir
  },

  "network": { "mode": "off", "allow": [], "log": false, "mitm": false },

  "mounts": {
    "agent_folder": "~/.agentdev/homes/myproject",                  // host dir as the agent home (omit = ephemeral)
    "read_only":  [ { "src": "~/ref", "dest": "/ref" } ],           // { src, dest } folder pairs
    "read_write": [ { "src": "~/out", "dest": "/out" } ],
    "history": "~/.agentdev/myproject/history",                     // optional: redirect this run's history
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

Every key is optional and takes a built-in default; omit a whole block to accept its defaults.

## 5. Interactive vs one-shot

- **Interactive (default):** agentdev drops you into a shell. Run `claude` / `omp` / `pi` yourself
  and pick the model inside.
- **One-shot (`one-shot` block, or `--prompt`):** agentdev runs the named agent headless on the
  prompt file, then exits. `agent` and `model` live here because this is the only mode where
  agentdev launches the agent.

## 6. The agent home, history, and memory

`mounts.agent_folder` is a plain host directory bound as the agent's home. Manage it yourself
(`cp` to fork, `tar` to move, `git` to version, `rm` to wipe).

- **Clean room:** omit `agent_folder` (and `history`/`memory`) — the home is fresh and discarded.
- **Persist:** set `agent_folder` to a kept folder; the agent's config, history, and memory live
  there across runs.
- **Split out history/memory:** set `mounts.history` and/or `mounts.memory` to separate host
  folders. agentdev mounts each at the agent's known location under the home, so you can reuse one
  `agent_folder` for config while keeping each run's history or memory separate for later analysis.
  Omit them and that data stays in `agent_folder` (or on the ephemeral container filesystem if
  that's omitted too — lost on exit).

Only Claude has a separable memory folder today; see [§9](#9-supported-agents).

## 7. Environment and credentials

**agentdev forwards no credentials through the config.** The agent reads everything it needs —
`ANTHROPIC_API_KEY`, `AWS_*`, a gateway `ANTHROPIC_BASE_URL`, `CLAUDE_CODE_USE_BEDROCK`, model
routing — from a **`.env` or `.envrc` in the workspace launch folder**. An interactive shell loads
it via `direnv`; a one-shot run sources it before invoking the agent.

To keep a secret out of your repo, put it in a private host file and inject it with
`workspace.files` (it is bound read-only into the working directory under the name you choose).

## 8. Network isolation

- `off` (default) — full internet.
- `none` — no network at all.
- `allowlist` — only `network.allow` destinations, via a filtering proxy sidecar; optional egress
  `log` and per-URL `mitm`. Add your model's host (e.g. `api.anthropic.com`) to `allow`.

Under `allowlist`, host names must be **fully qualified**: no LAN shortcuts. Write
`dgx1.example.lan`, never `dgx1`, and use the same name in `network.allow` and in the URL the agent
calls (e.g. `ANTHROPIC_BASE_URL`). The proxy sidecar resolves names on a podman bridge network that
does not carry your host's DNS `search` domain, so a short name fails, and the agent sees only an
empty reply. The allowlist also matches names as strings, so `dgx1` and `dgx1.example.lan` are
different entries.

The egress log (`network.log`) is written into the agent home, so set `mounts.agent_folder` to keep
it. For an untrusted task, combine `allowlist` with `workspace.mode: "ro"` and `workspace.ssh: false`
(see [`examples/isolated`](../examples/isolated)).

## 9. Supported agents

`one-shot.agent` is a short name mapped to the in-container executable:

| `agent` | Home | `mounts.memory`? | `mounts.history`? |
|---|---|---|---|
| `claude` | `~/.claude` + `~/.claude.json` | **yes** — `projects/<ws>/memory/` | **yes** — `projects/<ws>/` |
| `omp` | `~/.omp` | **yes** — `agent/memories/` | **no** — history is a DB |
| `pi` | `~/.pi` | **no** — no memory store | **yes** — `agent/sessions/` |

Claude is fully wired; `omp` and `pi` are present and selectable, with their headless command and
model environment best-effort for now.

## 10. Templates and examples

- `templates/<agent>/` — copy-by-hand starter kits (`agentdev-config.json` + the agent's
  instruction file + `env.example`). `cp -r templates/claude ./agentdev` and edit.
- `examples/minimal` — the smallest interactive config.
- `examples/isolated` — a locked-down headless run.
- `examples/persistent` — a kept home with split history/memory.
- `examples/one-shot-orchestrator` — fan many prompts across parallel one-shot runs.

## 11. Troubleshooting

| Symptom | Fix |
|---|---|
| `Error: ... unknown key` | A typo or a retired key; the message names it and the replacement. |
| `Error: no config file` | Pass `-c`, set `$AGENTDEV_CONFIG`, or add `./agentdev-config.json`. |
| `Error: agent 'X' has no separable memory/history folder` | Remove `mounts.memory`/`mounts.history` for that agent. |
| `Error: agent home is already in use` | Another run holds the same `agent_folder`; wait or remove the orphan container. |
| one-shot auth fails | Put `ANTHROPIC_API_KEY` in a `.env`/`.envrc` in the workspace (agentdev passes no credentials via config). |
| `Error: ... not an existing directory/file` | A mount source does not exist; agentdev is fail-closed on mounts. |
