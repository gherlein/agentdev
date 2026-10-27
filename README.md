# agentdev

Disclaimer: This works for me -- that's the entire guarantee. Built with AI in the loop, so check your own biases before you love it or hate it on principle. Use at your own risk, fork freely, and don't @ me when it explodes. (But do drop me a note if it helps -- pay it forward.)

Run a coding agent (Claude Code) in an isolated container where **one JSON config file
defines the entire launch**: the agent, the model it connects to, an optional one-shot
prompt, exactly which host folders are mounted (and whether each is read-only), and how
much of the internet the container can reach. Reading the file tells you what the
container gets — nothing important comes from outside it, and an unknown or invalid key
aborts the launch.

The agent's **home** is a swappable **profile folder** on the host — never your real
`~/.claude` — so you can run a **clean room** (no past), a **remembering agent with clean
history**, or a **named profile** that carries everything forward. Profiles and memory
stores are plain directories; agentdev never versions them and offers no management
subcommands — manage them with `cp`, `rm`, `tar`, and `git`.

> **Claude Code today; other agents next.** agentdev is agent-agnostic by design — a
> profile is "the home dir(s) for *this* agent." See [`VISION.md`](./VISION.md) for the
> full picture and [`DESIGN.md`](./DESIGN.md) for the implementation.

agentdev is **self-contained**: it ships its own container image, entrypoint, and mount
library, and depends on nothing but `podman` and `python3`.

📖 **New here? The [User Guide](./docs/user-guide.md) is the complete walkthrough** —
install, the config file, modes, auth, mounts, network, skills, and troubleshooting.

## Install

```bash
git clone <this repo> ~/src/agentdev && cd ~/src/agentdev
make build                       # build the container image once
make install                     # symlink the launcher into ~/.local/bin
export ANTHROPIC_API_KEY=sk-...  # for api-key auth (clean/remember modes)
```

`make` with no target lists everything (`build`, `test`, `lint`, `install`, `clean`, …).
Requirements: `podman`, `python3`, and Linux for `--userns=keep-id` ownership mapping.

The image bundles the full localdev toolset — Node LTS (nvm) + TypeScript/pnpm/eslint/
prettier, Go + TinyGo + gopls/dlv/goimports/kit/golangci-lint, `uv`, `gh`, podman-in-podman,
pandoc + WeasyPrint, the networking/SDR stack (nmap, tshark, aircrack-ng, hackrf, rtl-sdr,
soapysdr, hamlib, ax25, gpsd, usbutils) — plus the **[herdr](https://herdr.dev)** agent
orchestrator and the Claude Code CLI.

## Use

Create an `agentdev-config.json` (copy one from [`examples/`](./examples)) and run:

```bash
cd ~/src/my-project
cp ~/src/agentdev/examples/minimal/agentdev-config.json .

agentdev --dry-run          # print the settled plan and the exact podman command
agentdev                    # launch an interactive shell; run `claude` inside

# Run the agent once, headless, on a prompt from a file, then exit:
echo "fix the failing test" > task.md
agentdev --prompt task.md

# Run an arbitrary command instead of the shell:
agentdev -- bash -lc 'make test'
```

The **command line is tiny** — these are the only options:

| Option | Effect |
|---|---|
| `-c`, `--config <path>` | select the config file |
| `--dry-run` | print the settled plan and the `podman` command; launch nothing |
| `--prompt <file>` | run the agent once, headless, on the prompt in `<file>` (overrides `prompt.file`) |
| `-- COMMAND...` | run COMMAND instead of the shell |

Everything else — the agent, model, mounts, network, auth, trust, workspace — is in the
config file. The file is chosen in order: **`-c <path>` → `$AGENTDEV_CONFIG` →
`./agentdev-config.json`**.

## The config file

One JSON file is the whole truth. A key it omits takes its built-in default; nothing comes
from a user-level config or an environment variable. It is validated **fail-closed** — an
unknown key, wrong type, or invalid value aborts before the container starts (a typo in
`"netwrok"` is an error, not a silently-ignored security setting). Relative paths resolve
against the **config file's directory**. Keys starting with `//` are comments.

```json
{
  "agent":   { "name": "claude", "image": "ghcr.io/gherlein/agentdev:latest" },
  "model":   { "id": "claude-opus-5-5", "provider": "anthropic" },
  "profile": { "mode": "clean" },
  "auth":    { "mode": "auto" },
  "workspace": { "source": ".", "trust": "skip-permissions", "workdir": "." },
  "network": { "mode": "off" },
  "mounts":  {
    "workspace":  "rw",
    "read_only":  { "~/ref/api-docs": "/ref" },
    "read_write": { "~/out": "/out" }
  },
  "sandbox": { "ssh": true, "usb": true, "host_ca": true }
}
```

- **Agent** — `agent.name` (only `claude` so far) and the container `image`. Pin `image`
  by digest for a reproducible run (`make digest` prints the pin-by-digest ref); the
  examples use the moving `:latest` tag for readability.
- **Model** — `model.id` (→ `ANTHROPIC_MODEL`), `model.provider`
  (`anthropic`/`bedrock`/`vertex`), `model.base_url` (a gateway or self-hosted endpoint),
  and `model.pass_env` (host variables forwarded by name for provider credentials).
- **One-shot prompt** — `prompt.file` runs the agent headless on that file, then exits
  (the `--prompt` flag overrides it).
- **Mounts** — the workspace (`workspace.source`, default the config file's directory;
  `mounts.workspace: "ro"` for read-only), plus `mounts.read_only` / `mounts.read_write`
  maps and `mounts.devices`. Nothing else is mounted implicitly.
- **Network** — `network.mode`: `off` (full internet, default), `none`, or `allowlist`
  (only `network.allow` destinations, via a proxy sidecar, with optional egress logging).
- **Host passthroughs** — `sandbox.ssh` / `sandbox.usb` / `sandbox.host_ca` (all default
  `true`) pass host SSH keys + agent, `/dev/bus/usb`, and the host's extra CA anchors.
- **Profile** — `profile.mode` picks the mode (below); `profile.keep` retains a clean run.

Each seeded profile records `agentdev.meta.json` (template, mode, created-at) and
`agentdev.lock` (resolved image digest, Claude Code version, template + mount hashes), so a
profile is self-describing and a run is reproducible.

Preview any config with `--dry-run`. See [`docs/user-guide.md`](./docs/user-guide.md) for
every key and [`DESIGN.md`](./DESIGN.md) for the schema.

## Modes

`profile.mode` chooses where the agent's home lives and what survives:

| `profile.mode` | Memory | History | Lifetime |
|---|---|---|---|
| `clean` | fresh | fresh | throwaway, deleted on exit (`profile.keep: true` to retain) |
| `remember` (+ `profile.memory_store`) | persistent store | fresh | home discarded; store kept |
| `profile` (+ `profile.name`) | persistent | persistent | kept under `profile.profiles_root` |

Profiles and memory stores are plain folders under `profile.profiles_root` /
`profile.memory_root`. Manage them yourself: `cp -a` to fork, `rm -rf` to delete, `tar` to
move, `git` to version. agentdev seeds a profile on first launch and never silently
re-seeds it; to re-seed, delete the folder and relaunch.

## What isolation does and doesn't cover

A profile isolates the agent's **on-disk home** — config, history, memory, and local MCP
servers (`.mcp.json`). A clean run starts from the seed template with none of your real
`~/.claude`.

It does **not** isolate your **claude.ai account**. If you log the agent into a Claude
subscription, account-level **claude.ai connectors** (Atlassian, Microsoft 365, Slack,
Claude Docs, …) appear in the session even in a clean room — they follow whoever you log in
as, not the profile. A clean room is a clean *disk*, not a clean *account*. To keep a run
connector-free, use `auth.mode: "api-key-env"` (no subscription login) or disconnect the
connector in claude.ai. See
[`docs/managing-context-and-memory.md`](./docs/managing-context-and-memory.md).

## Skills from a shared store

A profile's `.claude/skills/` is a mounted part of its home, so you can populate it from
[`sm`](https://github.com/gherlein/sm)'s canonical skill store:

```bash
sm sync --copy --agent-home ~/.agentdev/profiles/research   # real dirs, container-safe
```

See [`docs/applying-sm-managed-skills.md`](./docs/applying-sm-managed-skills.md).

## Locked-down (skill-evaluation) runs

For an untrusted task or skill evaluation, use a config that locks the run down — allowlist
network with egress logging, read-only workspace, confirmed rw mounts, api-key auth, no
SSH. The ready example is [`examples/isolated/`](./examples/isolated):

```bash
agentdev -c examples/isolated/agentdev-config.json --prompt task.md
```

Egress is recorded (when `network.log: true`) to `<profile>/agentdev-egress.log`, a plain
tab-separated file you read with ordinary tools:

```bash
cut -f2,4 <profile>/agentdev-egress.log | sort | uniq -c | sort -rn
```

For fanning prompts across many tasks in parallel, see
[`examples/one-shot-orchestrator/`](./examples/one-shot-orchestrator/).

## Example configs

- [`examples/minimal/`](./examples/minimal) — the smallest sensible starting point.
- [`examples/profile-folder/`](./examples/profile-folder) — a folder-per-context setup with a `.envrc`.
- [`examples/isolated/`](./examples/isolated) — a locked-down config (allowlist net, read-only workspace, no SSH, api-key auth).
- [`examples/basic-skills/`](./examples/basic-skills) — a persistent profile that seeds a few basic skills from a template.

## Layout

```
agentdev              launcher (bash)
lib/                  config, mounts, model, net, seed, profile, memory, meta
                      (+ jsoncfg.py schema/reader, allowcheck.py)
image/                Containerfile + entrypoint.sh + proxy.py (egress allowlist sidecar)
                      → ghcr.io/gherlein/agentdev
templates/default/    seed template (CLAUDE.md, settings.json, hooks/, claude.json.seed)
examples/             ready-to-copy configs and the one-shot orchestrator
tests/                offline smoke + matrix, live and live-agent tiers, proxy unit tests
```

## Status

Implemented: one strict, fail-closed config file; `-c` / `$AGENTDEV_CONFIG` /
`./agentdev-config.json` resolution; clean / remember / named modes; model selection
(id / provider / base_url / forwarded credentials); `copy` template seeding with linting;
`auto` / api-key / inherit-credentials / interactive auth; network `off` / `none` /
`allowlist` with an egress proxy and logging; `--prompt` one-shot runs; plain-folder
profiles and memory stores; and `--dry-run`.

Not yet: agents other than Claude Code (the framing is in place; see `DESIGN.md` §10).
Deliberately out of scope: workspace copy-on-write / patch-review, overlay templates,
fleet / fan-out, cost accounting, and any profile/memory management subcommands — see
[`VISION.md`](./VISION.md).
