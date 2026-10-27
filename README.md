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

agentdev is **Linux-only** — it uses rootless `podman` and `--userns=keep-id`. Install it
from Homebrew to just use it, or from this repo to develop it.

### Install from Homebrew

The simplest path: a tagged release, with Homebrew managing `podman` for you.

**Prerequisite:** [Homebrew on Linux](https://docs.brew.sh/Homebrew-on-Linux) on your PATH
(`brew --version` works).

```bash
brew tap gherlein/tap
brew trust gherlein/tap          # a tap must be trusted before its formulae load
brew install agentdev
```

What this does: installs the `agentdev` launcher (symlinked into Homebrew's `bin`) and
`podman`, and unpacks the agentdev tree under `$(brew --prefix agentdev)/libexec`. The
container image is **not** bundled — it is pulled from `ghcr.io` on first launch
(`podman run --pull=missing`); pre-pull it with
`podman pull ghcr.io/gherlein/agentdev:latest`. Rootless podman also needs your distro's
user-namespace plumbing (`subuid`/`subgid`, `uidmap`); verify once with `podman info`.

Upgrade or remove:

```bash
brew upgrade agentdev
brew uninstall agentdev
```

### Install from the repo

Best for developing agentdev or running unreleased changes — the launcher runs straight
from your checkout.

**Prerequisites:** `git`, `podman`, `python3`, and Linux.

```bash
git clone https://github.com/gherlein/agentdev ~/src/agentdev && cd ~/src/agentdev
make build                       # build the container image once (ghcr.io/gherlein/agentdev:latest)
make install                     # symlink the launcher into ~/.local/bin (PREFIX overridable)
```

`make install` **symlinks** the launcher rather than copying it, so your edits and
`git pull` take effect immediately; the launcher resolves its sibling `lib/`, `templates/`,
and `image/` through that symlink (so the tree must stay in place). Ensure `~/.local/bin` is
on your PATH. `make` with no target lists every target (`build`, `test`, `lint`, `install`,
`uninstall`, `clean`, …); `make uninstall` removes the symlink.

The image bundles the full localdev toolset — Node LTS (nvm) + TypeScript/pnpm/eslint/
prettier, Go + TinyGo + gopls/dlv/goimports/kit/golangci-lint, `uv`, `gh`, podman-in-podman,
pandoc + WeasyPrint, the networking/SDR stack (nmap, tshark, aircrack-ng, hackrf, rtl-sdr,
soapysdr, hamlib, ax25, gpsd, usbutils) — plus the **[herdr](https://herdr.dev)** agent
orchestrator and the Claude Code CLI.

## Run it

Create an `agentdev-config.json` (copy one from [`examples/`](./examples)) and launch:

```bash
cd ~/src/my-project
cp ~/src/agentdev/examples/minimal/agentdev-config.json .

agentdev --dry-run          # print the settled plan and the exact podman command
agentdev                    # launch an interactive shell; run `claude` inside

# Run the agent once, headless, on a prompt from a file, then exit:
echo "fix the failing test" > task.md
agentdev --prompt task.md
```

Because the config file carries everything, the command line is just three flags:

| Flag | Effect |
|---|---|
| `-c`, `--config <path>` | select the config file (else `$AGENTDEV_CONFIG`, else `./agentdev-config.json`) |
| `--dry-run` | print the settled plan and the `podman` command, then exit — launch nothing |
| `--prompt <file>` | run the agent once, headless, on the prompt in `<file>`, then exit (overrides `prompt.file`) |

That is the entire surface — there are no modes, policies, or subcommands on the command
line. (Append `-- COMMAND` to run a command instead of the interactive shell; `-h` prints
usage.) Everything else lives in the config file, described next.

## The config file

One JSON file is the whole truth. Reading it tells you exactly what the container gets.

**How it is found.** `-c <path>` on the command line, else `$AGENTDEV_CONFIG`, else
`./agentdev-config.json` in the current directory. If none exists, agentdev refuses to
launch.

**How it is read.**

- **Fail-closed.** The file is validated against a strict schema *before any key is read*.
  An unknown or misspelled key, a wrong type, or a value outside its allowed set aborts the
  launch and names the offending key — a typo in `"netwrok"` is an error, never a silently
  ignored security setting.
- **Self-contained.** A key the file omits takes its built-in default; nothing comes from a
  user-level config file or an environment variable. There is no hidden layering.
- **Relative paths** (mount sources, `template.source`, `workspace.source`, `prompt.file`)
  resolve against the **config file's own directory**, so a committed config means the same
  thing wherever it is launched from.
- **Comments.** Any key beginning with `//` is ignored, at every level.

### Every key (all optional; defaults shown)

```jsonc
{
  "agent": {
    "name":  "claude",                            // only "claude" so far
    "image": "ghcr.io/gherlein/agentdev:latest"   // pin by digest for a reproducible run
  },
  "model": {
    "id":       "",                               // -> ANTHROPIC_MODEL (empty = agent default)
    "provider": "anthropic",                      // anthropic | bedrock | vertex
    "base_url": "",                               // a gateway or self-hosted endpoint URL
    "pass_env": []                                // host env var names to forward (credentials)
  },
  "prompt": {
    "file": ""                                    // run headless on this file, then exit
  },
  "profile": {
    "mode":          "clean",                     // clean | remember | profile
    "name":          "",                          // profile mode: which named profile
    "memory_store":  "default",                   // remember mode: which memory store
    "keep":          false,                        // clean mode: keep the throwaway profile
    "profiles_root": "~/.agentdev/profiles",
    "clean_root":    "~/.cache/agentdev/clean",
    "memory_root":   "~/.agentdev/memory"
  },
  "template": {
    "source":  "~/.agentdev/templates/default",   // seed template for a fresh profile
    "include": ["CLAUDE.md","settings.json","hooks","skills",".mcp.json"]
  },
  "auth": {
    "mode": "auto"                                // auto | api-key-env | interactive | inherit-credentials
  },
  "workspace": {
    "source":  ".",                               // host folder mounted at /<basename> (default: config dir)
    "trust":   "skip-permissions",                // skip-permissions | workspace-only | prompt
    "workdir": "."                                // entry folder: the shell's cwd (relative to the workspace)
  },
  "network": {
    "mode":  "off",                               // off | none | allowlist
    "allow": [],                                  // allowlist: reachable host[:port] rules
    "log":   false,                               // record egress to <profile>/agentdev-egress.log
    "mitm":  false                                // per-URL filtering (terminates TLS)
  },
  "mounts": {
    "workspace":  "rw",                           // rw | ro (the workspace mount mode)
    "confirm_rw": false,                          // prompt before each read-write mount
    "rw_allow":   [],                             // pre-approve rw sources under confirm_rw
    "read_only":  {},                             // { "host/src": "dest" } read-only mounts
    "read_write": {},                             // { "host/src": "dest" } read-write mounts
    "devices":    []                              // host device nodes to pass through
  },
  "sandbox": {
    "ssh":     true,                              // host SSH keys + agent socket
    "usb":     true,                              // /dev/bus/usb
    "host_ca": true                               // host extra TLS trust anchors
  }
}
```

### What each group does

- **`agent`** — which agent and which container image. `name` is `claude` for now; pin
  `image` by digest (`make digest` prints the ref) for a reproducible run. Examples use the
  moving `:latest` tag for readability.
- **`model`** — `id` → `ANTHROPIC_MODEL`; `provider` selects `anthropic` / `bedrock`
  (`CLAUDE_CODE_USE_BEDROCK`) / `vertex` (`CLAUDE_CODE_USE_VERTEX`); `base_url` points at a
  gateway or self-hosted endpoint; `pass_env` forwards host variables **by name**, so secrets
  never appear in argv or `--dry-run`. Under an allowlist the model's endpoint must itself be
  allowed, or the launch aborts.
- **`prompt`** — `file` runs the agent headless on that prompt, then exits (the `--prompt`
  flag overrides it).
- **`profile`** — `mode` picks clean / remember / named (see **Modes**); `name` and
  `memory_store` feed the latter two; `keep` retains a clean run; the `*_root` keys say where
  the plain folders live.
- **`template`** — the authored config copied into a fresh profile: the `source` folder and
  the `include` list of items to seed.
- **`auth`** — `auto` detects what the host uses; `api-key-env` forwards `ANTHROPIC_API_KEY`
  by name and seeds no credential file; `interactive` logs in inside the container;
  `inherit-credentials` copies the host's subscription login into a **named** profile (set on
  clean/remember it aborts — a throwaway home must not hold a copied secret).
- **`workspace`** — `source` is the host folder mounted at `/<basename>` (default: the config
  file's directory); `trust` controls the per-project trust dialog; `workdir` is the entry
  folder the shell starts in.
- **`network`** — `off` (full internet, default), `none` (no network), or `allowlist` (only
  `allow` destinations, via a filtering proxy sidecar, with optional `log` and `mitm`).
- **`mounts`** — the `workspace` mode (`rw`/`ro`), extra `read_only` / `read_write` folder
  maps and `devices`, plus a `confirm_rw` gate with its `rw_allow` pre-approvals. Nothing is
  mounted implicitly.
- **`sandbox`** — host passthroughs, each default `true`: `ssh` keys + agent, `usb`
  (`/dev/bus/usb`), and `host_ca` (extra TLS anchors).

Each seeded profile also records `agentdev.meta.json` (template, mode, created-at) and
`agentdev.lock` (resolved image digest, Claude Code version, template + mount hashes), so a
profile is self-describing and a run is reproducible.

Preview any config with `--dry-run`. See [`docs/user-guide.md`](./docs/user-guide.md) for the
narrative walkthrough and [`DESIGN.md`](./DESIGN.md) for the schema internals.

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
