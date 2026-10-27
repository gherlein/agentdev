# agentdev User Guide

A complete walkthrough of agentdev: installing it, the one config file that defines a
launch, the modes, auth, the model, mounts, network, the one-shot prompt, profiles and
memory, skills, MCP, and troubleshooting. For *why* it is built this way see
[`VISION.md`](../VISION.md); for *how* it is implemented see [`DESIGN.md`](../DESIGN.md).

## Contents

1. [What agentdev is](#1-what-agentdev-is)
2. [Install and requirements](#2-install-and-requirements)
3. [The command line](#3-the-command-line)
4. [The config file](#4-the-config-file)
5. [Modes](#5-modes)
6. [Authentication](#6-authentication)
7. [Trust](#7-trust)
8. [Selecting the model](#8-selecting-the-model)
9. [Mounting folders](#9-mounting-folders)
10. [Host passthroughs (SSH, USB, CA)](#10-host-passthroughs-ssh-usb-ca)
11. [Network and egress isolation](#11-network-and-egress-isolation)
12. [Running the agent on a prompt](#12-running-the-agent-on-a-prompt)
13. [Profiles and memory stores](#13-profiles-and-memory-stores)
14. [Skills](#14-skills)
15. [MCP servers and claude.ai connectors](#15-mcp-servers-and-claudeai-connectors)
16. [Running many agents (orchestration)](#16-running-many-agents-orchestration)
17. [Reproducibility](#17-reproducibility)
18. [Troubleshooting](#18-troubleshooting)
19. [Full config schema](#19-full-config-schema)

---

## 1. What agentdev is

agentdev runs a coding agent (Claude Code) inside a rootless podman container whose
**entire home is a profile folder on your host** — never your real `~/.claude`. **One JSON
config file defines the whole run.** Two things are mounted into every launch:

- **The profile** → the agent's home (`/home/developer/.claude` + `.claude.json`): config,
  history, memory, credentials.
- **The workspace** (`workspace.source`, default the config file's directory) → `/<basename>`,
  the only project code the agent sees.

Everything else stays outside unless the config mounts it. A profile is a plain folder;
agentdev never versions it.

## 2. Install and build

### Requirements

**podman**, **python3**, and **Linux** (for `--userns=keep-id` ownership mapping; macOS
works via a podman machine).

### Install the launcher

```bash
git clone https://github.com/gherlein/agentdev ~/src/agentdev && cd ~/src/agentdev
make install                     # symlink the launcher onto your PATH (~/.local/bin)
```

`make install` **symlinks** the launcher rather than copying it — it is not a single
self-contained file; it sources `lib/`, `templates/`, and `image/` from the checkout — so
your edits and `git pull` take effect immediately. `make uninstall` removes the symlink.

Or install a tagged release with Homebrew (`brew tap gherlein/tap && brew trust gherlein/tap
&& brew install agentdev`); see the [README](../README.md#install).

### Build the image

The agent runs inside a container image you build once with the Makefile — there is no
`agentdev build` subcommand:

```bash
make build                       # build ghcr.io/gherlein/agentdev:latest
make digest                      # print the pin-by-digest ref to set as agent.image
```

Re-run `make build` after changing anything under `image/`. A Homebrew install skips this
step — the image is pulled from ghcr.io on first launch.

## 3. The command line

The launcher does one thing: read a config file and launch the container. Its only options
are:

| Option | Effect |
|---|---|
| `-c`, `--config <path>` | select the config file |
| `--dry-run` | print the settled plan and the exact `podman` command; launch nothing |
| `--prompt <file>` | run the agent once, headless, on the prompt in `<file>` (§12) |
| `-- COMMAND...` | run COMMAND instead of the interactive shell |
| `-h`, `--help` | usage |

There are **no other flags and no subcommands.** The agent, model, mounts, network, auth,
trust, and workspace all live in the config file (§4). Profiles and memory stores are plain
folders you manage yourself (§13).

```bash
cd ~/src/my-project
cp ~/src/agentdev/examples/minimal/agentdev-config.json .
agentdev --dry-run     # check the plan first
agentdev               # launch an interactive shell; run `claude` (or `clauded`) inside
```

## 4. The config file

### Where it comes from

The config path is resolved in order:

1. **`-c` / `--config <path>`**
2. **`$AGENTDEV_CONFIG`**
3. **`./agentdev-config.json`** in the current directory

If none exists, agentdev refuses to launch. A `-c` or `$AGENTDEV_CONFIG` that points at a
missing file is an error.

### One file, strict, self-contained

Reading the file tells you the whole run. There is **no user-level config layer** and **no
environment-variable mount input** — a key the file omits takes its built-in default, and
nothing else. Relative paths (mount sources, `template.source`, `workspace.source`,
`prompt.file`) resolve against the **directory that holds the file**, so the file means the
same thing wherever you launch from.

The file is validated against a schema **before any key is read**. An unknown or misspelled
key, a wrong type, or a value outside its allowed set **aborts the launch and names the
offending key** — a typo can never silently disable a setting:

```
$ agentdev --dry-run
error: ./agentdev-config.json: netwrok: unknown key
error: ./agentdev-config.json: profile.keep: must be true or false (got "yes")
Error: config file failed validation: ./agentdev-config.json
```

Keys starting with `//` are treated as comments. The full schema is in §19.

### An example

Every key, with its default value, in one file — read it top to bottom and you see the
whole run. Any key you leave out falls back to exactly the default shown here:

```jsonc
{
  "agent": {
    "name":  "claude",                            // only "claude" so far
    "image": "ghcr.io/gherlein/agentdev:latest"   // pin by digest for a reproducible run
  },
  "model": {
    "id":       "claude-opus-5-5",                // -> ANTHROPIC_MODEL ("" = agent default)
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
    "include": ["CLAUDE.md", "settings.json", "hooks", "skills", ".mcp.json"]
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

Preview exactly what a config produces — mounts, model endpoint, network, auth — with
`agentdev --dry-run` before launching. For a ready-made starting point, copy
[`examples/minimal/agentdev-config.json`](../examples/minimal/) (or another
[`examples/`](../examples/)) and edit from there. Each key is documented in §19.

## 5. Modes

Set `profile.mode` in the config file to choose where the agent's home lives and what
survives:

| `profile.mode` | Config keys | Memory | History | Lifetime |
|---|---|---|---|---|
| `clean` (default) | — | fresh | fresh | throwaway, deleted on exit |
| `remember` | `profile.memory_store` | **persistent store** | fresh | home discarded; store kept |
| `profile` | `profile.name` | persistent | persistent | kept under `profile.profiles_root` |

- **clean** — a brand-new user: no prior transcripts, memory, or identity; a fresh
  `.claude.json`; discarded on exit. Set `profile.keep: true` to retain it (the path is
  printed).
- **remember** — a clean-room home with a persistent memory store mounted at the agent's
  auto-memory path, so it keeps what it learned but starts each session with a clean
  transcript.
- **profile** — a named profile under `profiles_root`, seeded once on first launch and
  reused thereafter so everything accumulates.

A profile is seeded **once** on first launch and never silently re-seeded. To re-apply the
template, delete the profile folder and relaunch.

## 6. Authentication

`auth.mode`:

| Mode | What it does |
|---|---|
| `auto` (default) | Detect: `ANTHROPIC_API_KEY` set → `api-key-env`; else a **profile** with a readable host login → `inherit-credentials`; else → `interactive`. |
| `api-key-env` | Forward `ANTHROPIC_API_KEY` into the container (by name, so the value never appears in the plan). Fails if unset. |
| `interactive` | Log in inside the container. Persists in a named profile; discarded in clean/remember. |
| `inherit-credentials` | **Named profiles only** (set on `clean`/`remember` it aborts fail-closed). Copy the host's `~/.claude/.credentials.json` into the profile and merge the host's claude.ai account block into its `.claude.json`. |

Notes:

- A **headless `--prompt` run needs non-interactive auth**: in clean/remember export
  `ANTHROPIC_API_KEY` (and `auth.mode: "api-key-env"` or `auto`); in a profile, `auto`
  inherits your host login.
- **inherit-credentials reuses your subscription login** (token *and* account) but cannot
  add an OAuth scope your host token lacks. If `claude doctor` inside reports a missing
  scope, run `claude auth login` once inside the profile; it persists.
- A **clean/remember run never inherits credentials** — a secret is never copied into a
  throwaway home.
- A **non-Anthropic model provider** (`model.provider` of `bedrock`/`vertex`)
  authenticates with its own credentials via `model.pass_env` (§8); `auth.mode` must be
  `auto`.

## 7. Trust

`workspace.trust` controls Claude Code's workspace trust dialog:

| Mode | Effect |
|---|---|
| `skip-permissions` (default) | Seeds nothing. Intended for running `claude --dangerously-skip-permissions` (the `clauded` alias). |
| `workspace-only` | Pre-accept the trust dialog for `/<workspace>` only. |
| `prompt` | Seeds nothing; the normal trust dialog appears. |

In an interactive shell, `skip-permissions` and `prompt` produce identical profiles — only
`workspace-only` changes what is seeded. agentdev never adds `--dangerously-skip-permissions`
to a `claude` you start yourself. A `--prompt` run always runs
`claude --dangerously-skip-permissions`, whatever `workspace.trust` says.

## 8. Selecting the model

`model.*` picks the model and where the agent reaches it. For Claude Code these are all
environment variables, so the same settings apply to an interactive run and a `--prompt`
run:

| Key | Effect |
|---|---|
| `model.id` | → `ANTHROPIC_MODEL` (e.g. `"claude-opus-5-5"`) |
| `model.provider` | `anthropic` (default), `bedrock` (`CLAUDE_CODE_USE_BEDROCK=1`), or `vertex` (`CLAUDE_CODE_USE_VERTEX=1`) |
| `model.base_url` | a gateway or self-hosted endpoint → `ANTHROPIC_BASE_URL` / `ANTHROPIC_BEDROCK_BASE_URL` / `ANTHROPIC_VERTEX_BASE_URL` |
| `model.pass_env` | host variables forwarded **by name** (provider credentials / region), e.g. `["AWS_REGION", "AWS_PROFILE"]` |

agentdev derives the model endpoint host (the default for the provider, or the host of
`model.base_url`). Under `network.mode: "allowlist"` (§11) that endpoint **must be on the
allowlist**, or agentdev aborts before launch. Forwarded `model.pass_env` values are passed
by name, so secrets never appear in the plan or `--dry-run` output.

## 9. Mounting folders

### The workspace

`workspace.source` is the host folder mounted at `/<basename>` (default: the config file's
directory). `mounts.workspace` is `"rw"` (default) or `"ro"` (read-only — the safe posture
for an untrusted or exploratory task). `workspace.workdir` is the **entry folder**: where
the container shell starts (empty/`"."` = the workspace root; a relative path resolves under
it; absolute is used as-is). A `.envrc` there is loaded automatically (direnv is in the
image; run `direnv allow` once).

### Extra folders

`mounts.read_only` and `mounts.read_write` are `"source": "destination"` maps:

```json
{
  "mounts": {
    "read_only":  { "~/ref/standards": "/external/standards", "../sibling-repo": "&" },
    "read_write": { "~/out/shared": "shared" }
  }
}
```

Destination rules: absolute → used literally; `"&"` → the source's basename at the
container root; relative → under the workspace (`/<basename>/<dest>`). Sources expand a
leading `~`; `$VAR` is not expanded. A source resolves against the **config file's
directory**.

A missing source, a non-directory, an unreadable source, or a target collision **aborts the
launch** (fail-closed) and names the offender. The workspace root and the agent's own paths
(`/home/developer/.claude`, `.claude.json`, `.ssh`, `.npm`, `mounts`, `.agentdev-prompt`,
`/ssh-agent`, the CA dir) are reserved and cannot be targeted; subpaths of the workspace are
fine. The full resolved mount plan is written to `/home/developer/mounts` inside, and
`--dry-run` prints it.

### Confirming read-write mounts

With `mounts.confirm_rw: true`, every rw mount (and the workspace, if rw) prompts
`Allow READ-WRITE mount <host> -> <target>? [y/N]` on the terminal; a run with no terminal
**denies** (fail-closed). Pre-approve known-good sources non-interactively with
`mounts.rw_allow: ["<path>", …]`.

### Devices

`mounts.devices` is a list of host device nodes passed through with `--device`, e.g.
`["/dev/ttyUSB0"]`. A missing or non-device path aborts the launch.

## 10. Host passthroughs (SSH, USB, CA)

Three host resources are passed through, each with its own key (all default `true`), and
each visible in `--dry-run`:

| Key | Passes through | When |
|---|---|---|
| `sandbox.ssh` | `~/.ssh` (ro) + `$SSH_AUTH_SOCK` | the dir / socket exist |
| `sandbox.usb` | `/dev/bus/usb` | the host has it |
| `sandbox.host_ca` | the host's extra CA anchors (ro) + `NODE_EXTRA_CA_CERTS` | the host has extra anchors |

Set any to `false` to withhold it — e.g. `sandbox.ssh: false` for a locked-down run. These
are the *only* host resources agentdev adds beyond the profile, the workspace, and the
mounts you list.

## 11. Network and egress isolation

`network.mode`:

| Mode | Container reach |
|---|---|
| `off` (default) | Full internet, podman's default networking |
| `none` | No network at all |
| `allowlist` | Only `network.allow` destinations, via a filtering proxy sidecar on an internal (no-egress) network |

Under `allowlist`, the agent joins an internal network with no route out; a proxy sidecar
(the only thing with egress) permits just the allowlist, so a client that ignores the proxy
and opens a raw socket reaches nothing. Include your model endpoint (e.g.
`api.anthropic.com`) or the agent can't reach its model — agentdev checks this before
launch.

Allowlist rules (`network.allow`, one per array element): `host`, `host:port`, `*.host`
(leading-wildcard), or `host/path`:

- **Domain level (default):** HTTPS is tunnelled by host, not decrypted. A `host/path` rule
  cannot be enforced on an opaque HTTPS tunnel, so it is refused unless MITM is on. Other
  protocols (git over SSH, raw TCP) do not pass the HTTP(S) proxy.
- **Per-URL (`network.mitm: true`):** the proxy terminates TLS with a generated CA the
  agent is told to trust and matches the full URL path. Heavier; can break pinned clients.

With `network.log: true`, every decision is appended to `<profile>/agentdev-egress.log`, a
plain tab-separated file (`ISO8601 ⇥ ALLOW|DENY ⇥ METHOD ⇥ host:port ⇥ path`). Read it with
ordinary tools:

```bash
cut -f2,4 <profile>/agentdev-egress.log | sort | uniq -c | sort -rn
```

A ready locked-down config is [`examples/isolated/`](../examples/isolated): allowlist net +
logging, read-only workspace, confirmed rw mounts, api-key auth, no SSH.

## 12. Running the agent on a prompt

To run the agent once, unattended, point it at a prompt **file** — either `prompt.file` in
the config or `--prompt <file>` on the command line (which overrides `prompt.file`):

```bash
cat > task.md <<'EOF'
Read DESIGN.md and implement the code.
EOF
agentdev --prompt task.md
```

agentdev mounts the file read-only and the agent reads it via `"$(cat …)"`, so the prompt
text never passes through a shell-quoted argument (any quotes, `$`, or backticks are
literal), runs **headless with permissions skipped** and stdin closed, and the container
exits (`--rm`) when the task finishes — `agentdev`'s exit status is the agent's. A prompt
cannot be combined with a `-- command`. `--prompt` is relative to the current directory;
`prompt.file` is relative to the config file. Auth still follows the mode (§6); preview with
`--dry-run`.

## 13. Profiles and memory stores

Profiles (`profile.profiles_root`, default `~/.agentdev/profiles`) and memory stores
(`profile.memory_root`, default `~/.agentdev/memory`) are **plain folders**. agentdev
creates and seeds them on first launch but offers **no management subcommands** — manage
them with ordinary tools:

```bash
cp -a ~/.agentdev/profiles/research ~/.agentdev/profiles/experiment   # fork
rm -rf ~/.agentdev/profiles/old                                       # delete
tar czf research.tgz -C ~/.agentdev/profiles research                 # archive / move
git -C ~/.agentdev/memory/research init                               # version (your choice)
```

**Only one run may hold a named profile at a time** — a profile is a shared, mutable
folder, and two writers would corrupt it. agentdev enforces this with a lock, a live-
container check, and a fixed container name per folder. If a crashed run leaves an orphaned
container holding a profile, the next launch tells you its id; reap it with `podman rm -f
<id>`. Clean and remember runs each get their own throwaway folder, so they are fully
concurrent.

The seeded profile carries a `.gitignore` that excludes `.credentials.json` and
`policy-limits.json`, so if you version a profile yourself, secrets stay out of the remote.

## 14. Skills

A profile's `.claude/skills/` is mounted and is in the default template include list, so
skills reach an agent two ways:

- **Template skills** — a `skills/` dir in your seed template (`template.source`) is copied
  into every seeded profile.
- **`sm`-managed skills** — populate a profile from a shared store with
  `sm sync --copy --agent-home <profile-folder>`.

The two coexist (sm's provenance marker keeps it from clobbering template or hand-placed
skills). See [`applying-sm-managed-skills.md`](./applying-sm-managed-skills.md) for why
`--copy` is required for containers.

## 15. MCP servers and claude.ai connectors

Three kinds, controlled differently:

- **Local / CLI servers** (`.mcp.json`, `claude mcp …`) — live in the profile; a clean run
  seeds none.
- **Plugin servers** — come with an installed plugin.
- **claude.ai connectors** (Atlassian, Microsoft 365, Slack, Claude Docs, …) —
  **account-level**, served by claude.ai's backend. They are **not** stored in the profile
  and follow whoever you log in as, so they appear even in a clean session once you sign
  into a subscription. A clean room is a clean *disk*, not a clean *account*.

To keep a run connector-free, use `auth.mode: "api-key-env"` (no subscription login) or
disconnect the connector in claude.ai. See
[`managing-context-and-memory.md`](./managing-context-and-memory.md).

## 16. Running many agents (orchestration)

To fan tasks out across isolated agents, a controller spawns one agentdev run per task and
collects each result. The pattern and a working harness are in
[`../examples/one-shot-orchestrator/`](../examples/one-shot-orchestrator/). Key rules: use
`profile.mode: "clean"` workers (no lock, fully concurrent) or forked profiles — never point
many runs at one named profile; and spawn siblings from the host, never nest agentdev inside
a worker container.

## 17. Reproducibility

Each seeded profile records two files:

- **`agentdev.lock`** — a pin of the exact `image` digest, Claude Code version, template
  hash, and mount-set hash.
- **`agentdev.meta.json`** — mode, run id, template source/hash, workspace basename, memory
  store.

Pin `agent.image` by `@sha256:…` digest (not a tag) for a run you can reproduce later.

## 18. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `Error: no config file` | No config is resolvable. Pass `-c <path>`, set `$AGENTDEV_CONFIG`, or create `./agentdev-config.json` (copy from `examples/`). |
| `<key>: unknown key` / `must be one of …` | The config failed validation. Fix or remove the named key — a typo is fatal, by design. |
| `Error: unknown argument 'profiles'` (or `doctor`, `init`, `build`, …) | Those subcommands were removed. Profiles/memory are plain folders (§13); build with `make build`; check a config with `--dry-run`. |
| `profile is already in use` | Another run holds it, or a crashed run's container is orphaned. The error prints the container id; reap it with `podman rm -f <id>`. |
| `network.mode=allowlist does not allow the model endpoint …` | Add the endpoint host to `network.allow`. |
| Headless prompt run hangs | Use `--prompt <file>` / `prompt.file` — it closes stdin and skips permissions. Check auth (§6). |
| `/mcp` shows connectors even in a clean run | Account-level claude.ai connectors follow your login, not the profile (§15). |
| Mount "collision" or "not an existing directory" | Two mounts resolve to the same target, or a source is missing / not a directory. See §9. |

## 19. Full config schema

Every key is optional; the value shown is the built-in default. `//` keys are comments.

```jsonc
{
  "agent": {
    "name":  "claude",                               // only "claude" so far
    "image": "ghcr.io/gherlein/agentdev:latest"      // pin by @sha256:… for reproducibility
  },
  "model": {
    "id":       "",                                  // → ANTHROPIC_MODEL; "" = agent default
    "provider": "anthropic",                         // anthropic | bedrock | vertex
    "base_url": "",                                  // gateway / self-hosted endpoint URL
    "pass_env": []                                   // host env var names to forward (credentials)
  },
  "prompt": {
    "file": ""                                       // run headless on this file, then exit
  },
  "profile": {
    "mode":          "clean",                        // clean | remember | profile
    "name":          "",                             // profile mode: which named profile
    "memory_store":  "default",                      // remember mode: which store
    "keep":          false,                          // clean mode: retain the profile
    "profiles_root": "~/.agentdev/profiles",
    "clean_root":    "~/.cache/agentdev/clean",
    "memory_root":   "~/.agentdev/memory"
  },
  "template": {
    "source":  "<install-dir>/templates/default",
    "include": ["CLAUDE.md", "settings.json", "hooks", "skills", ".mcp.json"]
  },
  "auth": {
    "mode": "auto"                                   // auto | api-key-env | interactive | inherit-credentials
  },
  "workspace": {
    "source":  ".",                                  // host folder mounted at /<basename>; default = the config dir
    "trust":   "skip-permissions",                   // skip-permissions | workspace-only | prompt
    "workdir": ""                                    // entry folder (bash cwd); ""/"." = workspace root
  },
  "network": {
    "mode":  "off",                                  // off | none | allowlist
    "allow": [],                                     // host | host:port | *.host | host/path
    "log":   false,                                  // record egress to <profile>/agentdev-egress.log
    "mitm":  false                                   // per-URL HTTPS filtering (needs openssl)
  },
  "mounts": {
    "workspace":  "rw",                              // rw | ro
    "confirm_rw": false,                             // prompt before every read-write mount
    "rw_allow":   [],                                // pre-approve rw sources under confirm_rw
    "read_only":  {},                                // "host-src": "dest"
    "read_write": {},                                // "host-src": "dest"
    "devices":    []                                 // host device nodes to pass through
  },
  "sandbox": {
    "ssh":     true,                                 // host SSH keys + agent
    "usb":     true,                                 // /dev/bus/usb
    "host_ca": true                                  // host extra TLS anchors
  }
}
```

Any error in the config — invalid JSON, an unknown key, a wrong type, an out-of-range value
— aborts before the container starts (fail-closed).

See also: [`README.md`](../README.md) (overview), [`DESIGN.md`](../DESIGN.md)
(implementation), [`managing-context-and-memory.md`](./managing-context-and-memory.md),
[`applying-sm-managed-skills.md`](./applying-sm-managed-skills.md),
[`../examples/`](../examples/).
