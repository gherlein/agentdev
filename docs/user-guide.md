# agentdev User Guide

A complete walkthrough of agentdev: installing it, launching agents, the modes,
auth, trust, mounting folders, profiles, memory, skills, MCP, orchestration,
configuration, and troubleshooting. For *why* it is built this way see
[`VISION.md`](../VISION.md); for *how* it is implemented see
[`DESIGN.md`](../DESIGN.md).

## Contents

1. [What agentdev is](#1-what-agentdev-is)
2. [Install and requirements](#2-install-and-requirements)
3. [Launching a session](#3-launching-a-session)
4. [Modes](#4-modes)
5. [Authentication](#5-authentication)
6. [Trust and permissions](#6-trust-and-permissions)
7. [Mounting folders (read-only / read-write)](#7-mounting-folders-read-only--read-write)
8. [Named profiles](#8-named-profiles)
9. [Memory](#9-memory)
10. [Skills](#10-skills)
11. [MCP servers and claude.ai connectors](#11-mcp-servers-and-claudeai-connectors)
12. [Running many agents (orchestration)](#12-running-many-agents-orchestration)
13. [Skill-evaluation sandbox](#13-skill-evaluation-sandbox)
14. [Configuration](#14-configuration)
15. [Reproducibility](#15-reproducibility)
16. [Troubleshooting](#16-troubleshooting)
17. [Command and flag reference](#17-command-and-flag-reference)

---

## 1. What agentdev is

agentdev runs a coding agent (Claude Code, in phase 1) inside a rootless podman
container whose **entire home is a profile folder on your host** — never your real
`~/.claude`. Two things are mounted into every run:

- **The profile** → the agent's home (`/home/developer/.claude` + `.claude.json`).
  This holds its config, history, memory, and credentials.
- **Your current directory** → the read-write **workspace** at `/<dirname>`. This
  is the only project code the agent sees.

Everything else (your real home, your shell, other projects) stays outside. A
profile is a plain folder — agentdev never versions it; put one under git
yourself if you want history.

## 2. Install and requirements

Requirements: **podman**, **python3**, and **Linux** (for
`--userns=keep-id` ownership mapping; macOS works via a podman machine).

```bash
git clone <this repo> ~/src/agentdev && cd ~/src/agentdev
make build                       # build the container image once
make install                     # symlink the launcher onto your PATH (~/.local/bin)
make doctor                      # verify podman, image, template, (api key if configured)
export ANTHROPIC_API_KEY=sk-...  # needed for clean/remember modes (see §5)
```

Without `make`: `agentdev build`, `agentdev doctor`, and symlink `agentdev` onto
your `PATH` yourself. Re-run `agentdev build` after changing the image.

## 3. Launching a session

Launch from the project directory you want the agent to work in:

```bash
cd ~/src/my-project
agentdev --clean           # interactive shell in a fresh throwaway agent
agentdev --profile work    # a persistent named profile
```

A mode (or any launch argument) is required — **bare `agentdev` prints usage and
exits**; it does not launch. Inside, you get a shell as user `developer` with your
directory at `/<dirname>`; run `claude` (or `clauded` = `claude
--dangerously-skip-permissions`) there.

**Run a one-shot command** instead of a shell — everything after `--` runs
verbatim, and the container exits when it finishes:

```bash
agentdev --clean -- claude --dangerously-skip-permissions -p "fix the failing test"
```

**Preview without launching** — prints the settled plan and the exact `podman`
command:

```bash
agentdev --clean --dry-run
```

See the root README's "Run a one-shot command (autonomous agent)" for the full
autonomous-run contract (auth + permissions).

## 4. Modes

Modes are mutually exclusive; the default comes from config (built-in: `clean`).

| Mode | Flag | Config | Memory | History | Lifetime |
|---|---|---|---|---|---|
| **Clean** | `--clean` | seeded fresh | none | none | throwaway, deleted on exit |
| **Remember** | `--remember [store]` | seeded fresh (throwaway home) | **persistent store** | fresh | home discarded; store kept |
| **Named profile** | `--profile <name>` | seeded once, then drifts | persistent | persistent | kept |

Modifiers:

- `--keep` — clean mode only: keep the throwaway profile and print its path (to
  inspect what the run did).
- `--reseed` — re-apply the template's *config* items over an existing profile,
  leaving its memory and history intact.
- `--template <path>` — use a different seed template for this run.

Rule of thumb: **clean** for reproducible one-shots and experiments; **remember**
for "learn across runs but start each with a clean transcript"; **profile** for a
durable, evolving identity.

## 5. Authentication

Set with `--auth <mode>` or `auth.mode` in config. `--login` is shorthand for
`--auth interactive`.

| Mode | What it does |
|---|---|
| `auto` (default) | Detect: if `ANTHROPIC_API_KEY` is set → `api-key-env`; else for a **profile** with a readable host login → `inherit-credentials`; else → `interactive`. |
| `api-key-env` | Forward `ANTHROPIC_API_KEY` into the container. Fails if unset. |
| `interactive` | Log in inside the container. The login persists in a named profile; it is discarded in clean/remember. |
| `inherit-credentials` | **Named profiles only.** Copy the host's `~/.claude/.credentials.json` into the profile, and merge the host's claude.ai account block (`oauthAccount`, `hasAvailableSubscription`, `userID`) into the profile's `.claude.json`. |

Notes:

- **Headless `claude -p` needs non-interactive auth.** In clean/remember, export
  `ANTHROPIC_API_KEY` and use `--auth api-key-env`.
- **inherit-credentials reuses your subscription login** (token *and* account, so
  connectors and managed settings work) — but it cannot add an OAuth scope your
  host token never had. If `claude doctor` inside reports "subscription auth not
  active" or "missing the `user:profile` scope", sign in once inside the profile
  with `claude auth login`; because the profile persists, it sticks.
- **A clean/remember run does not inherit credentials** — a secret is never copied
  into a throwaway home.

## 6. Trust and permissions

`--trust <mode>` (or `workspace.trust` in config; built-in default
`skip-permissions`) controls the workspace trust dialog:

| Mode | Effect |
|---|---|
| `skip-permissions` | No trust prompt for the workspace. |
| `workspace-only` | Pre-accept the trust dialog for `/<dirname>` (seeds `hasTrustDialogAccepted`). |
| `prompt` | Leave Claude Code's normal trust prompt in place. |

Trust is about the *trust dialog*, not per-tool permissions. For a fully
**autonomous** run that edits files unattended, also pass
`--dangerously-skip-permissions` **on the `claude` command itself** (the image's
`clauded` alias is the shorthand). Trust alone will still leave the agent stopping
for per-tool approvals.

## 7. Mounting folders (read-only / read-write)

Your launch directory is always the read-write workspace. To mount *additional*
host folders, there are three mechanisms, unioned together.

### a. CLI flags (per run)

```bash
agentdev --clean -ro ~/ref/api-docs      # read-only
agentdev --clean -rw ~/out               # read-write
agentdev --clean ~/ref/specs             # bare path = read-only
agentdev --clean /dev/ttyUSB0            # /dev/* = device passthrough
```

`-ro`/`-rw` are repeatable and mixable. A CLI mount always appears inside at
`/external/<basename>` — the CLI form cannot choose the destination (use the config
maps for that). A bare path must be an existing directory.

### b. `mounts.read_only` / `mounts.read_write` in the config (committable)

The `mounts` group of `./agentdev-config.json` (or `~/.agentdev/config.json`) applies
on every launch. Scaffold a starter config with `agentdev init`. Each is a
`"source": "destination"` map:

```json
{
  "mounts": {
    "read_only": {
      "~/ref/standards": "/external/standards",   // absolute container path
      "../sibling-repo": "&"                        // "&" → basename at root → /sibling-repo
    },
    "read_write": {
      "~/out/shared": "shared"                      // relative → under workspace → /<dirname>/shared
    }
  }
}
```

Destination rules: absolute → used literally; `"&"` → the source basename at the
container root; relative → under the workspace. Sources accept `~` and `$VAR`.
Relative sources and `"&"` are portable (safe to commit in the project config);
host-specific absolute paths belong in `~/.agentdev/config.json`. An invalid config
aborts the launch.

Two things about relative paths:

- **The two "relative" anchors differ.** A relative *source* is resolved against
  the directory you launch from (the host side). A relative *destination* is
  resolved under the **workspace** (`/<dirname>`, the container side). A relative
  source + relative destination is the portable combination — the folder lands at
  a stable path inside the workspace regardless of absolute host locations.
- **A destination under the workspace is a nested mount and shadows your PWD.**
  `"~/out/build" = "build"` mounts at `/<dirname>/build`, so the agent sees the
  mounted source there, not any `./build` your launch directory actually contains.
  That is usually the intent (a generated-output or shared-assets dir), but be
  deliberate — the real `./build` is hidden for that run. You cannot target the
  workspace root `/<dirname>` itself (it is reserved); subpaths are fine.

### c. `AGENTDEV_MOUNTS` env var (read-only)

```bash
AGENTDEV_MOUNTS="$HOME/ref/a $HOME/ref/b" agentdev --clean
```

Whitespace-separated host dirs, each mounted read-only. Good for machine-wide
defaults in your shell profile.

### Rules for all three

- The folder must exist and be a directory (non-existent paths warn and skip).
- **One mount per container destination** — a collision is fatal. The workspace
  root `/<dirname>` and the agent's own paths are reserved and cannot be targeted
  (`/home/developer/.claude`, `.claude.json`, `.ssh`, `.npm`, `mounts`,
  `/ssh-agent`, the CA dir); subpaths of the workspace are fine.
- `--dry-run` prints the full resolved mount plan (`-v host:container:mode`).
- The whole mount map is written to `/home/developer/mounts` inside, so the agent
  can see what it has.

## 8. Named profiles

```bash
agentdev profiles ls              # list profiles
agentdev profiles show <name>     # print a profile's meta.json
agentdev profiles new <name>      # create and seed without launching
agentdev profiles fork <src> <dst>  # copy a profile (a cheap, full clone)
agentdev profiles rm <name>       # delete a profile
agentdev profiles gc              # sweep crashed clean-room leftovers AND reap orphaned profile containers
```

**Only one run may hold a named profile at a time.** A profile is a shared,
mutable folder; two concurrent runs would corrupt each other. agentdev enforces
this with a lock plus a live-container check and a fixed container name (see
`DESIGN.md` §2.5). If you want parallelism from one identity, `profiles fork` it
per worker, or use clean mode. If a crashed run leaves a container holding a
profile, `agentdev profiles gc` reaps it.

## 9. Memory

`--remember [store]` gives a throwaway home plus a **persistent memory store**
mounted at the agent's auto-memory path (`.claude/projects/<enc>/memory`), so the
agent keeps what it learns across runs while each session starts with a clean
transcript. The default store is `default`; name one to share it across repos.

```bash
agentdev --remember            # default store
agentdev --remember research   # a named store

agentdev memory ls             # list stores
agentdev memory new <name>     # create a store
agentdev memory rm <name>      # delete a store
```

A store is a plain folder under `memory_root` (default `~/.agentdev/memory`);
agentdev never versions it. This is the same mechanism as Claude Code's own
auto-memory (`MEMORY.md` + on-demand detail files); see
[`managing-context-and-memory.md`](./managing-context-and-memory.md).

## 10. Skills

A profile's `.claude/skills/` is mounted and is in the default template include
list, so skills reach an agent two ways:

- **Template skills** — put a `skills/` dir in your seed template; it is copied
  into every seeded profile.
- **`sm`-managed skills** — populate a profile from a shared store with
  `sm sync --copy --agent-home <profile>`.

The two coexist (sm's provenance marker keeps it from clobbering template or
hand-placed skills). Full details, including why `--copy` is required for
containers, are in
[`applying-sm-managed-skills.md`](./applying-sm-managed-skills.md).

## 11. MCP servers and claude.ai connectors

There are three kinds of MCP server and they are controlled differently:

- **Local / CLI servers** (`.mcp.json`, `claude mcp …`) — live in the profile; a
  clean run seeds none.
- **Plugin servers** — come with an installed plugin.
- **claude.ai connectors** (Atlassian, Microsoft 365, Slack, Claude Docs, …) —
  **account-level**, served by claude.ai's backend. They are **not** stored in the
  profile and follow whoever you log in as, so they appear even in a `--clean`
  session once you sign into a subscription. A clean room is a clean *disk*, not a
  clean *account*.

To keep a worker connector-free, use `--auth api-key-env` (no subscription login)
or disconnect the connector in claude.ai. See the README's "What isolation does
and doesn't cover" and [`managing-context-and-memory.md`](./managing-context-and-memory.md)
for the full control surface.

## 12. Running many agents (orchestration)

To fan tasks out across isolated agents, a controller spawns one agentdev
instance per task and collects each result. The pattern, the gotchas, and a
working harness (`orchestrate.sh` + `worker.sh` + `selftest.sh`) are in
[`../examples/one-shot-orchestrator/`](../examples/one-shot-orchestrator/). A
companion skill, `skills/orchestrate-agentdev/`, teaches an agent to drive it.

Key rules: use `--clean` workers (no lock, fully concurrent) or forked profiles —
never point many runs at one `--profile`; and **spawn siblings from the host,
never nest** agentdev inside a worker container.

## 13. Skill-evaluation sandbox

A locked-down profile for *evaluating skills*: no network except an allowlist,
every read-write mount confirmed, a read-only workspace, and no host SSH. One
flag turns it all on:

```bash
export ANTHROPIC_API_KEY=sk-...                       # eval uses api-key auth, not a subscription
agentdev --eval --profile skill-eval -- \
  claude --dangerously-skip-permissions -p "use the available skills to do X"
```

`--eval` sets these (each still overridable by an explicit flag or config):

| Policy | `--eval` value | Why |
|---|---|---|
| Network | `allowlist` (default allow = `api.anthropic.com`), egress logged | No exfiltration path beyond what you list |
| Workspace | read-only | Skills can't mutate the eval harness |
| RW mounts | confirm each (fail-closed with no TTY) | No silent write access |
| Auth | `api-key-env` | No subscription → no claude.ai connectors leak in |
| Trust | `workspace-only` | Not `skip-permissions` |
| SSH | off | No host keys/agent in the sandbox |

### Provisioning the skills under test

The skills come from `sm` (copy mode) or a template — not from `--eval`:

```bash
# put ONLY the skills under test in a store, then copy them into the profile
sm sync --copy --store ~/eval-skills --agent-home ~/.agentdev/profiles/skill-eval
```

(see [`applying-sm-managed-skills.md`](./applying-sm-managed-skills.md)).

### Tuning it with config instead of the preset

Spell the policy out in the harness directory's `./agentdev-config.json` (a ready
example ships at `templates/skill-eval/agentdev-config.json.example`):

```json
{
  "network": {
    "mode":  "allowlist",
    "allow": ["api.anthropic.com", "registry.npmjs.org:443"],
    "log":   true
  },
  "mounts": {
    "workspace":  "ro",
    "confirm_rw": true
  },
  "sandbox": {
    "ssh": false
  }
}
```

Allowlist entries are `host`, `host:port`, `*.wildcard.host`, or `host/path/prefix`
(one per line / array element).

### How the network lockdown works

`--net=allowlist` puts the agent on an **internal** podman network (no route out)
and runs a small **proxy sidecar** that is the only thing with egress. The agent
reaches the outside *only* through the proxy, which permits just the allowlist
and refuses everything else — so a skill that ignores the proxy and opens a raw
socket reaches nothing. `--net=none` is the fully-offline variant.

- **Domain level (default):** HTTPS is tunnelled by host (`host:port`), not
  decrypted. A `host/path` rule can't be enforced on an opaque HTTPS tunnel, so
  it is refused unless MITM is on.
- **Per-URL (tier 3, `mitm = true`):** the proxy terminates TLS with a generated
  CA the agent is told to trust, and matches the full URL path. Heavier and can
  break pinned clients — use only when you truly need path filtering. Requires
  `openssl` in the image (shipped).

### Confirming read-write mounts

With `confirm_rw`, every rw mount prompts `Allow READ-WRITE mount <host> -> <target>? [y/N]`
on the terminal; a run with no terminal **denies** (fail-closed). For automation,
pre-approve a known-good set non-interactively:

```bash
agentdev --eval --rw-allow ~/eval-out --profile skill-eval -rw ~/eval-out -- …
```

### Reviewing what the run reached

Egress is logged (under `--eval`); summarize it afterward:

```bash
agentdev report skill-eval
#   requests: 12   allow: 11   deny: 1
#   destinations (count  decision  host:port):
#       9  ALLOW  api.anthropic.com:443
#       1  DENY   telemetry.example.com:443
```

(The log lives at `<profile>/agentdev-egress.log`, so use a persistent `--profile`
or `--keep` to retain it.)

### A complete example

```bash
# 1. build a store with just the skills to evaluate
mkdir -p ~/eval-skills && cp -r ~/src/my-plugin/skills/my-skill ~/eval-skills/

# 2. create and provision the eval profile
agentdev profiles new skill-eval
sm sync --copy --store ~/eval-skills --agent-home ~/.agentdev/profiles/skill-eval

# 3. preview the locked-down plan
ANTHROPIC_API_KEY=$KEY agentdev --eval --profile skill-eval --dry-run

# 4. run the evaluation (writes only to the approved output dir)
ANTHROPIC_API_KEY=$KEY agentdev --eval --rw-allow ~/eval-out \
  --profile skill-eval -rw ~/eval-out -- \
  claude --dangerously-skip-permissions -p "Exercise my-skill on the fixtures in /agentdev and write results to /external/eval-out"

# 5. audit egress
agentdev report skill-eval
```

## 14. Configuration

All configuration is JSON. Resolution order, first found wins per key (CLI flags,
applied after, always win):

1. `./agentdev-config.json` (per project, committable) — or any path given with `-c/--config`
2. `~/.agentdev/config.json` (user; honors `AGENTDEV_HOME`)
3. built-in defaults

Keys are grouped and ordered the same everywhere. Full schema with built-in defaults
(every key optional; `//` comments are for the docs only — JSON has none):

```json
{
  "agent": {
    "name":  "claude",
    "image": "ghcr.io/gherlein/agentdev:latest"    // pin by @sha256:… for reproducibility
  },
  "profile": {
    "default_mode":  "clean",                       // clean | remember | profile
    "name":          "",                            // profile mode: which named profile (else --profile)
    "memory_store":  "default",                     // remember mode: which store (else --remember <store>)
    "keep":          false,                          // clean mode: retain the profile (like --keep)
    "profiles_root": "~/.agentdev/profiles",
    "clean_root":    "~/.cache/agentdev/clean",
    "memory_root":   "~/.agentdev/memory"
  },
  "template": {
    "source":   "<install-dir>/templates/default",
    "strategy": "copy",
    "include":  ["CLAUDE.md", "settings.json", "hooks", "skills", ".mcp.json"]
  },
  "auth": {
    "mode": "auto"                                  // auto | api-key-env | interactive | inherit-credentials
  },
  "workspace": {
    "isolation": "mount",
    "trust":     "skip-permissions",                // skip-permissions | workspace-only | prompt
    "workdir":   ""                                 // entry folder (bash cwd); relative to workspace, or absolute; ""/"." = root
  },
  "network": {                                      // sandbox / skill-eval policy (all off by default; see §13)
    "mode":  "off",                                 // off | allowlist | none
    "allow": [],                                    // host | host:port | *.host | host/path (for allowlist)
    "log":   false,                                 // record egress for `agentdev report`
    "mitm":  false                                  // tier 3: per-URL HTTPS filtering (needs openssl)
  },
  "mounts": {
    "workspace":  "rw",                             // rw | ro
    "confirm_rw": false,                            // prompt before every read-write mount
    "rw_allow":   [],                               // pre-approve rw mounts under confirm_rw (like --rw-allow)
    "read_only":  {},                               // "host-src": "dest"  (see §12b)
    "read_write": {}
  },
  "sandbox": {
    "ssh": true                                     // mount host SSH keys / agent
  }
}
```

A config file that fails to parse aborts the launch (fail-closed). `agentdev init`
writes a starter `./agentdev-config.json` in the launch directory.

## 15. Reproducibility

Each seeded profile records two files:

- **`agentdev.lock`** — a pin of the exact `image` digest, Claude Code version,
  template hash, and mount-set hash used.
- **`agentdev.meta.json`** — mode, run id, template source/hash, workspace
  basename, memory store.

Pin `agent.image` by `@sha256:…` digest (not a tag) for a run you can reproduce
later; `agentdev doctor` warns when the image is a floating tag.

## 16. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Bare `agentdev` prints usage, doesn't launch | By design — pass a mode (`agentdev --clean`). |
| `profile is already in use by another agentdev run` | Another run holds it, or a crashed run's container is orphaned. `agentdev profiles gc` reaps orphans; otherwise wait for the other run. |
| `/mcp` shows "No MCP servers configured" in a profile | The profile isn't signed into claude.ai. Run `claude auth login` inside; it persists. See §5. |
| `/mcp` shows connectors even in `--clean` | Those are account-level claude.ai connectors following your login, not profile config. See §11. |
| Headless `claude -p` hangs | Missing `--dangerously-skip-permissions` (per-tool approvals) and/or auth (`--auth api-key-env` + `ANTHROPIC_API_KEY`). See §5–6. |
| `claude doctor`: "subscription auth not active" / "missing user:profile scope" | The inherited host token lacks the scope; `claude auth login` inside the profile mints a fresh one. §5. |
| Mount "collision" error | Two mounts resolve to the same container path, or you targeted a reserved path. See §7. |
| Build/env problems | `agentdev doctor` checks podman, image, template, and (for `api-key-env`) the key. |

## 17. Command and flag reference

```
agentdev [MODE] [OPTIONS] [MOUNT-ARGS...] [-- COMMAND...]

Modes:    --clean | --remember [store] | --profile <name>
Options:  --template <path> | --auth <mode> | --login | --trust <mode>
          --keep | --reseed | --dry-run
Mounts:   -ro <path> | -rw <path> | <dir> (ro) | /dev/* (device)
Sandbox:  --eval | --net <off|allowlist|none> | --confirm-rw | --rw-allow <path>
          --workspace-ro | --no-ssh

Subcommands:
  profiles  ls | show <name> | new <name> | rm <name> | fork <src> <dst> | gc
  memory    ls | new <name> | rm <name>
  report <profile>   show a profile's egress log (from --net=allowlist)
  doctor    check the environment
  init      write a starter ./agentdev-config.json
  build     build the agentdev image locally
```

See also: [`README.md`](../README.md) (overview),
[`DESIGN.md`](../DESIGN.md) (implementation),
[`managing-context-and-memory.md`](./managing-context-and-memory.md),
[`applying-sm-managed-skills.md`](./applying-sm-managed-skills.md),
[`../examples/one-shot-orchestrator/`](../examples/one-shot-orchestrator/).
