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

📖 **New here? The [User Guide](./docs/user-guide.md) is the complete, end-to-end
walkthrough** — install, modes, auth, trust, mounting folders, profiles, memory,
skills, MCP, orchestration, configuration, and troubleshooting. This README is the
quick overview.

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

Requirements: `podman`, `python3`, and Linux for
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

### What isolation does and doesn't cover

A profile isolates the agent's **on-disk home** — its config, history, memory, and
any locally-registered MCP servers (`.mcp.json`). A `--clean` run starts from the
seed template with none of your real `~/.claude` config. That is filesystem
isolation.

It does **not** isolate your **claude.ai account**. If you log the agent into a
Claude subscription (the default interactive auth), **claude.ai connectors** —
account-level MCP servers like Atlassian, Microsoft 365, Slack, or Claude Docs,
configured in claude.ai and served by its backend — appear in the session even in
`--clean` mode. They are not stored in the profile and were not put there by
agentdev; they follow whoever you log in as, the same way they would in any Claude
Code session on that account. So:

- `/mcp` inside the container will list those connectors, with 0 local MCP servers
  of agentdev's own.
- A "clean room" is a clean **disk**, not a clean **account**.

To control them, work at the account/login level, not the profile:

- Disconnect the connector in **claude.ai** settings (affects every session), or
- `/mcp` → toggle it off in-session (persists in a `--profile`, but is discarded
  each run in `--clean`), or
- Use an **API-key-only** session (`--auth api-key-env`, no subscription login),
  which generally does not surface subscription connectors.

See [`docs/managing-context-and-memory.md`](./docs/managing-context-and-memory.md)
for the three kinds of MCP server and how each is controlled.

### Run a one-shot command (autonomous agent)

Everything after `--` is run **verbatim** as the container's command instead of an
interactive shell. The container runs that one command and exits (`--rm`), and
`agentdev` exits with the command's status — so this is how you drive a single,
unattended agentic task:

```bash
agentdev --profile myproj -- \
  claude --dangerously-skip-permissions -p "read the spec and implement the code"
```

Four things to get right for an unattended run:

- **Working directory is your repo.** The command runs at `/<dirname>` — the current
  directory bind-mounted in — so the agent reads the spec and edits the code in place.
  Run `agentdev` from the project you want worked on.
- **Auth depends on mode.** In **profile** mode, `auth = auto` inherits your host
  subscription login — both the token and the claude.ai account block — into the
  profile, so `claude -p` works with connectors and managed settings. (If your host
  login lacks a needed scope, sign in once inside the profile with `claude auth
  login`; it persists.) In **clean** and **remember** modes credential inheritance
  is disabled, so export `ANTHROPIC_API_KEY` and add `--auth api-key-env`.
- **Grant permissions explicitly.** A headless run that edits files will otherwise
  stall on tool-approval prompts. Pass `--dangerously-skip-permissions` (or
  `--permission-mode acceptEdits`) **on the `claude` command itself** — the image's
  `clauded` alias does *not* expand here, because the command is exec'd directly, not
  through an interactive shell. `agentdev --trust` only pre-accepts the *trust
  dialog*, not per-tool permissions, so it is not enough on its own.
- **Preview first.** Prefix with `--dry-run` to see the exact `podman` command,
  resolved auth/trust, and that your prompt survived quoting — before a real,
  file-mutating run.

For fanning this out across many tasks in parallel, see
[`examples/one-shot-orchestrator/`](./examples/one-shot-orchestrator/).

### Skills from a shared store

A profile's `.claude/skills/` is a first-class, mounted part of its home, so you
can populate it from [`sm`](https://github.com/gherlein/sm)'s
canonical skill store and the agent in the container reads those skills as its
own:

```bash
sm sync --copy --agent-home ~/.agentdev/profiles/research   # real dirs, container-safe
agentdev --profile research -- claude --dangerously-skip-permissions -p "…"
```

See [`docs/applying-sm-managed-skills.md`](./docs/applying-sm-managed-skills.md)
for the full integration (why `--copy`, the two skill channels, and lifecycle).

### Skill-evaluation sandbox

To evaluate skills in a locked-down agent — no network except an allowlist, every
read-write mount confirmed, a read-only workspace, no host SSH — use `--eval`:

```bash
agentdev --eval --profile skill-eval -- \
  claude --dangerously-skip-permissions -p "use the available skills to do X"
agentdev report skill-eval          # audit what the run reached on the network
```

Provision the skills under test with `sm sync --copy --agent-home <profile>`. Full
details (the allowlist proxy, per-URL MITM tier, confirming mounts, the egress
report) are in [`docs/user-guide.md` §13](./docs/user-guide.md#13-skill-evaluation-sandbox).

## Management

```bash
agentdev profiles ls|show|new|rm|fork|gc   # manage named profiles (plain folders)
agentdev memory   ls|new|rm                # manage memory stores (plain folders)
agentdev doctor               # check API key, podman, image, template
agentdev init                 # write a starter ./agentdev-config.json
agentdev build                # (re)build the image from image/Containerfile
```

## Configuration

Every CLI flag has a matching key in a **JSON config file**. By default agentdev reads
`./agentdev-config.json` if present; point elsewhere with `-c/--config <path>`. Resolution
is first-found-wins per key:

```
CLI flags  →  ./agentdev-config.json (or -c <path>)  →  ~/.agentdev/config.json  →  built-in defaults
```

The JSON keys are grouped and ordered the same everywhere: **agent, profile, template,
auth, workspace, network, mounts, sandbox**. A complete, annotated example lives in
[`examples/profile-folder/`](./examples/profile-folder). The idea: keep one folder per
working context holding its `agentdev-config.json` and a `.envrc`, and launch the agent so
its shell starts right there (`workspace.workdir`, or `--workdir`). Minimal example:

```json
{
  "agent":     { "image": "ghcr.io/gherlein/agentdev@sha256:…" },
  "profile":   { "default_mode": "profile", "name": "api-work" },
  "template":  { "source": "~/.agentdev/templates/default" },
  "workspace": { "trust": "skip-permissions", "workdir": "services/api" }
}
```

`workspace.workdir` (new) is the **entry folder**: where the container shell starts (the
bash cwd). Empty or `"."` is the workspace root; a relative path resolves under it; an
absolute path is used as given. A `.envrc` in that folder is loaded automatically (direnv
is in the image; run `direnv allow` once). CLI `--workdir <path>` overrides it per run.

Keys are the same two-tier split as before: commit a portable `./agentdev-config.json`
per project, and keep host-specific defaults (an image digest, custom roots) in
`~/.agentdev/config.json`. `agentdev init` scaffolds a starter file. See
[`DESIGN.md` §5](./DESIGN.md) for the full schema.

Ready-to-copy sample configs:

- [`examples/profile-folder/`](./examples/profile-folder) — a folder-per-context setup with a `.envrc`.
- [`examples/isolated/`](./examples/isolated) — a locked-down profile (allowlist net, read-only workspace, no SSH, api-key auth) for untrusted code or skill evaluation.
- [`examples/basic-skills/`](./examples/basic-skills) — an everyday persistent profile that seeds a few basic skills (`run-tests`, `git-commit`, `review-diff`) from a bundled template.

## Layout

```
agentdev              launcher (bash)
lib/                  config, mounts, seed, profile, memory, meta (+ jsoncfg.py)
image/                Containerfile + entrypoint.sh  → ghcr.io/gherlein/agentdev
templates/default/    seed template (CLAUDE.md, settings.json, hooks/, claude.json.seed)
```

## Status

Phase 1 (this repo): clean / remember / named modes, `copy` template seeding with linting,
plain-folder profiles and memory stores (agentdev never versions them), api-key /
interactive auth, trust seeding, the full management surface, and `--dry-run`. Phase 2
(network allowlist, copy-on-write / patch-only
workspace, cost reporting) and Phase 3 (fleet, multi-agent) are described in the vision.
