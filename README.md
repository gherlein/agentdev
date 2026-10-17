# agentdev

Run a coding agent in an isolated container whose **entire "self"** — authored config,
generated history, and learned memory — lives in a single, swappable, git-backed **profile
folder** on the host. Run it as a **clean room**, as a **remembering agent with clean
history**, or against a **named profile** that carries everything forward.

> **Phase 1 supports Claude Code only; other agents are next.** agentdev is agent-agnostic
> by design — a profile is simply "the home dir(s) for *this* agent." See
> [`VISION.md`](./VISION.md) for the full picture and [`DESIGN.md`](./DESIGN.md) for the
> implementation.

agentdev is **self-contained**: it ships its own container image, entrypoint, and mount
library, and depends on nothing but `podman`, `git`, and `python3`.

## Install

```bash
git clone <this repo> ~/src/agentdev
ln -s ~/src/agentdev/agentdev ~/bin/agentdev     # or add the repo to PATH
agentdev build                                   # build the container image once
agentdev doctor                                  # verify the environment
export ANTHROPIC_API_KEY=sk-...                  # needed for clean/remember modes
```

Requirements: `podman`, `git`, `python3` (3.11+ for `tomllib`), and Linux for
`--userns=keep-id` ownership mapping.

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

# Keep a clean run's profile to inspect what it did, then diff it.
agentdev --clean --keep
agentdev diff

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
agentdev profiles ls|show|new|rm|fork|snapshot|gc
agentdev memory   ls|new|rm|diff|log|revert
agentdev diff [profile]       # a run's footprint vs. its seed (git diff)
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
git-backed profiles and memory stores, api-key / interactive auth, trust seeding, the full
management surface, and `--dry-run`. Phase 2 (network allowlist, copy-on-write / patch-only
workspace, cost reporting) and Phase 3 (fleet, multi-agent) are described in the vision.
