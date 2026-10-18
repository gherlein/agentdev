# agentdev

Run a coding agent in an isolated container whose **entire "self"** — authored config,
generated history, and learned memory — lives in a single, swappable **profile folder** on
the host. Run it as a **clean room**, as a **remembering agent with clean history**, or
against a **named profile** that carries everything forward. Folders are plain directories;
agentdev never versions them — put one under git yourself if you want history.

> **Phase 1 supports Claude Code only; other agents are next.** agentdev is agent-agnostic
> by design — a profile is simply "the home dir(s) for *this* agent." See
> [`VISION.md`](./VISION.md) for the full picture and [`DESIGN.md`](./DESIGN.md) for the
> implementation.

agentdev is **self-contained**: it ships its own container image, entrypoint, and mount
library, and depends on nothing but `podman` and `python3`.

## Install

```bash
git clone <this repo> ~/src/agentdev && cd ~/src/agentdev
make build                       # build the container image once
make install                     # symlink the launcher into ~/.local/bin
make doctor                      # verify the environment
export ANTHROPIC_API_KEY=sk-...  # needed for clean/remember modes
```

`make` with no target lists everything (`build`, `test`, `lint`, `install`, `clean`, …).
The same actions are available without make: `agentdev build`, `agentdev doctor`,
`tests/smoke.sh`, and symlinking `agentdev` onto your `PATH`.

Requirements: `podman`, `python3` (3.11+ for `tomllib`), and Linux for
`--userns=keep-id` ownership mapping.

The image bundles the full localdev toolset — Node LTS (nvm) + TypeScript/pnpm/eslint/
prettier, Go + TinyGo + gopls/dlv/goimports/kit/golangci-lint, `uv`, `gh`, podman-in-podman,
the `opencode`/`omp` agents, pandoc + WeasyPrint, the networking/SDR stack (nmap, tshark,
aircrack-ng, hackrf, rtl-sdr, soapysdr, hamlib, ax25, gpsd, usbutils) — plus the
**[herdr](https://herdr.dev)** agent orchestrator and the Claude Code CLI.

## Use

```bash
cd ~/src/my-project

# Clean room: fresh agent, no history, no memory, discarded on exit.
agentdev --clean

# Remember what you learn, but start each session with a clean transcript.
agentdev --remember                 # default memory store
agentdev --remember research        # a named store, shareable across repos

# Fully persistent named profile — remembers everything.
agentdev --profile research

# Keep a clean run's profile so you can inspect (or version) what it did yourself.
agentdev --clean --keep

# Seed from a specific template; add reference material and a shared output dir.
agentdev --clean --template ~/configs/minimal-claude -ro ~/ref/api-docs -rw ~/out

# See exactly what would run, change nothing.
agentdev --clean --dry-run

# Run a command instead of an interactive shell.
agentdev --clean -- claude --dangerously-skip-permissions -p "fix the failing test"
```

The current working directory is the read-write workspace at `/<dirname>` inside the
container and is the only project code the agent sees. Its **home**, however, is the
profile — never your real `~/.claude`.

## Management

```bash
agentdev profiles ls|show|new|rm|fork|gc   # manage named profiles (plain folders)
agentdev memory   ls|new|rm                # manage memory stores (plain folders)
agentdev doctor               # check API key, podman, image, template
agentdev init                 # write a starter .agentdev-mounts.toml
agentdev build                # (re)build the image from image/Containerfile
```

## Configuration

TOML, resolved CLI → `./.agentdev.toml` → `~/.agentdev/config.toml` → built-in defaults
(first found wins per key; CLI always wins). See [`DESIGN.md` §5](./DESIGN.md) for the full
schema. Minimal example:

```toml
# ~/.agentdev/config.toml
[agent]
image = "ghcr.io/gherlein/agentdev@sha256:…"   # pin by digest for reproducibility
[profile]
default_mode = "clean"
[template]
source = "~/.agentdev/templates/default"
[workspace]
trust = "skip-permissions"                      # skip-permissions | workspace-only | prompt
```

## Layout

```
agentdev              launcher (bash)
lib/                  config, mounts, seed, profile, memory, meta (+ toml.py)
image/                Containerfile + entrypoint.sh  → ghcr.io/gherlein/agentdev
templates/default/    seed template (CLAUDE.md, settings.json, hooks/, claude.json.seed)
```

## Status

Phase 1 (this repo): clean / remember / named modes, `copy` template seeding with linting,
plain-folder profiles and memory stores (agentdev never versions them), api-key /
interactive auth, trust seeding, the full management surface, and `--dry-run`. Phase 2
(network allowlist, copy-on-write / patch-only
workspace, cost reporting) and Phase 3 (fleet, multi-agent) are described in the vision.
