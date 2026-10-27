# agentdev — Technical Design

> Companion to [`VISION.md`](./VISION.md). This document specifies the implementation
> (Claude Code only): the component breakdown, the minimal CLI, the one config file, the
> on-disk formats, and the two algorithms that matter — **seeding** a profile and building
> the **mount plan**. It describes the code as it stands.
>
> **One config file defines the launch** (agent, model, optional one-shot prompt, mounts,
> network), chosen by `-c` / `$AGENTDEV_CONFIG` / `./agentdev-config.json` and validated
> fail-closed. The CLI is just `--dry-run`, `-c`, and `--prompt`; there are no management
> subcommands. The deliberately out-of-scope items (workspace copy-on-write / patch-review,
> overlay templates, fleet / fan-out, cost accounting, other agents) are listed in §11.

**agentdev is self-contained.** It ships its own container image, its own entrypoint, and
its own mount library — it does **not** depend on localdev's code, image, or launchers at
runtime or build time. localdev is prior art that proved several patterns worth adopting
(non-root user with UID remap, `--userns=keep-id`, a host-home symlink so absolute config
paths resolve, a union mount grammar, host CA + SSH passthrough); agentdev **implements
those patterns itself** and inverts the one choice that matters: the agent's home is a
profile, never the host's real `~/.claude`. Verified against Claude Code CLI 2.1.300.

---

## 1. The core design: a profile is the agent's whole home

Everything hangs on a single decision. The agent inside the container gets a home that is
**one profile folder and nothing else** — no host `~/.claude`, no host credentials, no
host history:

```bash
# agentdev: the agent's home is a profile folder we created/resolved
PROFILE_MOUNT=(
  "-v" "$PROFILE/.claude:/home/developer/.claude:rw"
  "-v" "$PROFILE/.claude.json:/home/developer/.claude.json:rw"
)
# remember mode additionally overlays a persistent memory store on top (see §7):
#   -v "$MEMORY_STORE:/home/developer/.claude/projects/$ENC/memory:rw"
```

For this to work, two image-level mechanisms (both authored by agentdev, §2.1) must hold:

1. **UID/GID remap** — the container `developer` user is remapped to the host UID/GID at
   startup so files the agent writes into the bind-mounted profile are owned correctly on
   the host. Launched with `--userns=keep-id` on Linux.
2. **Host-home symlink** — the entrypoint symlinks the host's absolute `$HOME` to
   `/home/developer` inside the container, so any absolute path baked into config (plugin
   JSON, cached tool paths) resolves even though the physical home is `/home/developer`.
   This is what lets us mount the profile at `/home/developer/.claude` while the agent
   still sees it at `$HOME/.claude`.

localdev chose to bind the host's *real* `~/.claude` here (the agent "is you"). agentdev
makes the opposite choice — that inversion is the entire product — and owns the code on
both sides of it.

---

## 2. Architecture overview

agentdev is one repo with **no external runtime dependency** beyond `podman` and
`python3` (for JSON config parsing, already a Claude Code prerequisite), and the agentdev image
it builds and publishes.

```
agentdev (this repo)
├── agentdev                     ← the launcher (bash); the only entry point
├── lib/
│   ├── mounts.sh                ← OUR mount-collection library (union grammar, collisions, CA, SSH)
│   ├── profile.sh               ← resolve / create / lock / fork / gc a profile (plain folders)
│   ├── seed.sh                  ← template → profile (lint, copy, scaffold, .claude.json)
│   ├── memory.sh                ← resolve a memory store; compute the deterministic path
│   ├── config.sh                ← layered JSON/flag resolution (§5)
│   ├── jsoncfg.py               ← dotted-key JSON reader (get | list | table | check)
│   ├── net.sh                   ← network modes, proxy sidecar, egress report (§5.2)
│   └── meta.sh                  ← write & read agentdev.meta.json / agentdev.lock
├── image/
│   ├── Containerfile            ← builds ghcr.io/gherlein/agentdev (hardened, non-root)
│   ├── entrypoint.sh            ← UID/GID remap, host-home symlink, CA rebuild, gosu exec
│   └── proxy.py                 ← egress allowlist proxy, run as a sidecar from this image
├── templates/default/           ← the seed template (CLAUDE.md, settings.json, hooks/…)
├── tests/
└── DESIGN.md / VISION.md / README.md
```

### 2.1 The image (`image/Containerfile` → `ghcr.io/gherlein/agentdev`)

Authored fresh, not derived from localdev's image, but it carries the **full localdev
toolset** so the agent has everything to work with. Debian slim base, **non-root
`developer` user** (UID 1000), `NOPASSWD` sudo for the entrypoint's privileged steps, and:

- **The Claude Code CLI** (native installer) and **[herdr](https://herdr.dev)**, the agent
  orchestrator this project is driven through (`herdr.dev/install.sh`).
- **Node LTS** via nvm + TypeScript / ts-node / pnpm / eslint / prettier.
- **Go** + **TinyGo** + gopls / goimports / dlv / kit / golangci-lint / gofi, and `uv`.
- **`gh`**, **podman-in-podman** (rootless), `git`, `gosu`, `ca-certificates`, `stow`,
  `zoxide`, `direnv`, `tmux`, build toolchain.
- **pandoc + WeasyPrint**, ffmpeg, imagemagick, qpdf (docs/media).
- The **networking / wireless / SDR stack**: nmap, tshark, aircrack-ng, hackrf, rtl-sdr,
  soapysdr, hamlib, ax25, gpsd, usbutils, libpcap.
- The **`opencode`** and **`omp`** agents (present as tools; agentdev still only
  *manages profiles for* Claude — see §10).
- `ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]`, default `CMD ["bash"]`.

For a reproducible run the image should be pinned **by digest** (`make digest` prints the
pin-by-digest ref to set as `agent.image`); the shipped default and the examples use the
moving `:latest` tag for readability. Whatever the config names, `agentdev.lock` records the
image's resolved digest when the image is present locally (else the ref it was given), so a
seeded profile is self-describing regardless of later tag movement (VISION N2). The Claude
Code version the installer resolves is captured into the lock at seed time (§6).

### 2.2 The entrypoint (`image/entrypoint.sh`)

Authored fresh. Responsibilities, in order:

1. If running as root: `usermod`/`groupmod` the `developer` user to `$HOST_UID`/`$HOST_GID`,
   rename its login to `$HOST_USER`, and point its home field at `$HOST_HOME`.
2. Create the **`$HOST_HOME → /home/developer` symlink** (the mechanism in §1).
3. If `$REFRESH_CA_CERTS=1`, rebuild the system trust bundle so the host's extra CA
   anchors (bind-mounted by the launcher) are honored by curl/git/node.
4. `exec gosu "$HOST_USER" "$@"` (or `exec "$@"` when already non-root under
   `--userns=keep-id`).

### 2.3 The mount library (`lib/mounts.sh`)

Authored fresh. Mounts come **only from the config file** — `mounts.read_only` /
`mounts.read_write` maps and `mounts.devices` — with no CLI or env-var mount input:

- `collect_mounts` — single entry point; turns the config maps + devices into
  `VOLUME_MOUNTS` / `DEVICE_MOUNTS` / `MOUNTS_CONTENT`. A source that is missing, not a
  directory, or unreadable, or a device that does not exist, **aborts the launch**
  (fail-closed) and names the offender.
- `register_target` — claims one container-side target per source; a second claim on the
  same target is **always fatal** (collision detection). Reserves the workspace and the
  managed agent paths (including `/home/developer/.agentdev-prompt`) up front.
- `resolve_dir` — normalizes/validates a host source (must be an existing, readable
  directory). Sources are anchored at the config file's directory (`anchor_path`).
- `collect_host_ca_mount` — bind the host's extra TLS anchors read-only + set
  `NODE_EXTRA_CA_CERTS` (gated by `sandbox.host_ca`).

Grammar: `source = destination`, where destination is an absolute container path, a path
relative to the workspace, or `&` to mirror a relative source's basename at the container
root. Relative paths and `&` are portable/committable; absolute host paths are host-specific.

### 2.4 Control flow of one launch

```
agentdev [--dry-run] [-c <config>] [--prompt <file>] [-- command...]
  │
  ├─ resolve config path (-c > $AGENTDEV_CONFIG > ./agentdev-config.json)
  ├─ load_config: validate against the schema (fail-closed), settle every key, anchor paths
  ├─ resolve workspace (workspace.source) + model (setup_model, endpoint) + auth
  ├─ resolve profile.mode → PROFILE path (clean_root/<run-id> | profiles_root/<name>)
  ├─ if profile absent OR clean:  seed.sh   (lint template, copy, scaffold, .claude.json, .gitignore guard)
  ├─ if remember:                 memory.sh (resolve store, compute $ENC, ensure mount point)
  ├─ lock the profile (flock) + assert no live container (named mode: refuse 2nd concurrent use — §2.5)
  ├─ collect_mounts (config maps + devices); collect_host_ca_mount (if sandbox.host_ca)
  ├─ build PROFILE_MOUNT (+ MEMORY_MOUNT); register_target the memory path
  ├─ assert_model_endpoint_allowed (allowlist); setup_network (off | none | allowlist + proxy)
  ├─ assemble podman argv (workspace, userns, usb, ssh, ca, api-key/pass_env, model, HOST_* env, profile)
  │     --dry-run prints the settled plan + full podman command and EXITS here
  ├─ podman run ... ghcr.io/gherlein/agentdev@sha256:…  (bash by default, --prompt, or trailing -- command)
  └─ on exit (trap): teardown network; rm -rf if clean & !profile.keep ; named/kept folders left as-is
```

### 2.5 Single-instance guarantee for named profiles

A named profile is a shared, persistent folder that the run mounts **read-write** and
mutates live (`.claude/`, `.claude.json`). Two runs on the same profile at once would be
two writers of one folder — last-writer-wins corruption of `.claude.json`, racing writes
to history. So the invariant is: **at most one run may hold a named profile at a time.**
The resource being protected is the *folder*, not any one process; the launcher and the
container are both just writers of it. Clean and `remember` modes need no guard — each run
gets its own `clean_root/<run-id>` folder, so there is nothing shared to protect.

The guarantee is layered, because no single mechanism covers every failure:

1. **`flock` on `<profile>/.agentdev.lock-file`** (`lock_profile`). Held by the launcher
   for its lifetime; serializes two launchers racing through the seed/prep window before
   any container exists. The fd is **not** inherited by the podman child (`{FD}>&-` on the
   `podman run`), so an orphaned container can't pin the lock, and a dead launcher releases
   it immediately.

2. **Live-writer assertion** (`assert_profile_free`). `flock` only sees *launchers*; it
   cannot see a container that is still mounting the folder after its launcher was killed.
   So before launching we also refuse if `podman ps` shows a running container labeled
   `agentdev.profile=<path>`. This is the authoritative test of "is the folder being
   written right now," and it prints the orphan's container id so the user can
   `podman rm -f <id>`.

3. **Fixed container name** (`--name agentdev-<sha256(path)[:12]>`). The runtime itself is
   the backstop: podman refuses a second `run` while a container with that name exists, and
   `--rm` frees the name exactly when the container stops. This holds even across `kill -9`
   of the launcher, closing the gap between layers 1 and 2.

Every container carries the `agentdev.profile=<path>` label, so an orphan left by a crashed
run is easy to find (`podman ps -a --filter label=agentdev.profile`) and remove by hand.
agentdev itself runs no reaper — there is no management surface.

---

## 3. Component breakdown

| Component | File | Responsibility |
|---|---|---|
| **Launcher** | `agentdev` | Arg parse (`-c`/`--dry-run`/`--prompt`/`--`), orchestrate, assemble `podman run`, exit trap |
| **Image** | `image/Containerfile` | Hardened non-root image with Node + Claude Code CLI |
| **Entrypoint** | `image/entrypoint.sh` | UID/GID remap, host-home symlink, CA rebuild, gosu exec |
| **Config resolver** | `lib/config.sh` | Resolve the one config file, validate it (via `jsoncfg.py`), settle every key; anchor relative paths at the file's dir |
| **Schema/reader** | `lib/jsoncfg.py` | `get`/`list`/`table`/`check`/`validate`; the strict schema lives here |
| **Mount library** | `lib/mounts.sh` | Config mount maps + devices → `podman` args, collisions, reserved targets, host CA |
| **Model** | `lib/model.sh` | `model.*` → env args; derive the endpoint; allowlist interlock (`allowcheck.py`) |
| **Profile manager** | `lib/profile.sh` | Resolve path per mode, create dir, single-instance guard (`flock` + live-container assert + fixed `--name`, §2.5) |
| **Seeder** | `lib/seed.sh` | Lint template, copy `include`, build runtime scaffold + `.claude.json`, `.gitignore` secrets guard |
| **Memory manager** | `lib/memory.sh` | Resolve store under `memory_root`, compute `$ENC`, create mount point |
| **Network** | `lib/net.sh` | `network.*` → networks + proxy sidecar; teardown |
| **Meta/lock writer** | `lib/meta.sh` | `agentdev.meta.json`, `agentdev.lock` (image digest, CLI ver, template hash) |

The launcher sources the `lib/*.sh` files; shared state is a small set of globals
(`VOLUME_MOUNTS`, `DEVICE_MOUNTS`, `MOUNTS_CONTENT`, `MODEL_ARGS`, `NET_ARGS`, plus
agentdev's `PROFILE`, `MODE`, `ENC`, `MEMORY_STORE`). There are **no management
subcommands**: the launcher only launches (with `--dry-run` to preview).

---

## 4. CLI surface

```
agentdev [--dry-run] [-c <config>] [--prompt <file>] [-- COMMAND...]
```

The launcher does one thing: read a config file and launch the container. Its **only**
options are:

| Option | Effect |
|---|---|
| `-c, --config <path>` | Select the config file (else `$AGENTDEV_CONFIG`, else `./agentdev-config.json`) |
| `--dry-run` | Print the settled plan and the full `podman` command; **do not launch** |
| `--prompt <file>` | Run the agent once, headless, on the prompt in `<file>` (overrides `prompt.file`; relative to the current dir). Mounts the file read-only and runs `claude --dangerously-skip-permissions -p "$(cat …)" </dev/null`; cannot combine with `-- <command>` |
| `-- <command...>` | Run an arbitrary command instead of interactive `bash` (e.g. `-- bash -lc 'make test'`). Not for prompts |
| `-h, --help` | Usage |

There are **no modes, options, or subcommands beyond these**. Mode (`profile.mode`),
model, auth, trust, mounts, network, and workspace all come from the config file (§5).
Profiles and memory stores are plain folders managed with ordinary tools (no `profiles`/
`memory`/`report`/`doctor`/`init`/`build` subcommands); the image is built with
`make build`. A removed flag (`--clean`, `--net`, `-ro`, …) produces an error naming the
config key to set, as a migration aid.

**Default command.** The container's default command is interactive `bash`; the user runs
`claude` (or the `clauded` alias) inside. `--prompt`/`prompt.file` builds the headless
command itself, so the prompt is never a shell-quoted argument and stdin never blocks.

---

## 5. Configuration & resolution

The sole format is a **single JSON config file** that declares the whole launch. Keys are
grouped and ordered consistently (**agent, model, prompt, profile, template, auth,
workspace, network, mounts, sandbox**).

### Resolution

The config path is `-c/--config <path>`, else `$AGENTDEV_CONFIG`, else
`./agentdev-config.json`; if none exists, agentdev refuses to launch. There is **no
user-level config layer and no environment-variable mount input** — a key the file omits
takes its built-in default, and nothing else. A `-c`/`$AGENTDEV_CONFIG` that points at a
missing file, invalid JSON, or a schema violation **aborts before the container starts**
(fail-closed). Relative paths (mount sources, `template.source`, `workspace.source`,
`prompt.file`) resolve against the **directory that holds the file**, so the file means the
same thing wherever it is launched from.

### Strict schema

`lib/jsoncfg.py` holds the schema and a `validate` verb; `load_config` runs it before
reading any key. An **unknown or misspelled key, a wrong type, or a value outside its enum
aborts** and names the offending key — a typo can never silently disable a setting. Keys
starting with `//` are comments. The `get`/`list`/`table` verbs descend dotted keys for the
settled values; booleans are real JSON booleans.

The **profile**, **memory store**, **template**, and **workspace** each resolve to exactly
one authoritative value — one agent home and one workspace per run.

```jsonc
// agentdev-config.json  (every key shown; all are optional; // keys are comments)
{
  "agent": {
    "name":  "claude",                               // only "claude" so far
    "image": "ghcr.io/gherlein/agentdev@sha256:…"    // agentdev's own image, pinned by digest
  },
  "model": {
    "id":       "claude-opus-5-5",                   // → ANTHROPIC_MODEL
    "provider": "anthropic",                         // anthropic | bedrock | vertex
    "base_url": "",                                  // gateway / self-hosted endpoint URL
    "pass_env": []                                   // host env var names to forward (credentials)
  },
  "prompt": {
    "file": ""                                       // run headless on this file, then exit
  },
  "profile": {
    "mode":          "clean",                        // clean | remember | profile
    "name":          "api-work",                     // profile mode: which named profile
    "memory_store":  "default",                      // remember mode: which store
    "keep":          false,                           // clean mode: retain the profile
    "profiles_root": "~/.agentdev/profiles",
    "clean_root":    "~/.cache/agentdev/clean",
    "memory_root":   "~/.agentdev/memory"
  },
  "template": {
    "source":  "~/.agentdev/templates/default",
    "include": ["CLAUDE.md", "settings.json", "hooks", "skills", ".mcp.json"]
  },
  "auth": {
    "mode": "auto"                                   // auto | api-key-env | interactive | inherit-credentials
  },
  "workspace": {
    "source":  ".",                                  // host folder mounted at /<basename>; default = the config dir
    "trust":   "skip-permissions",                   // skip-permissions | workspace-only | prompt
    "workdir": "services/api"                        // ENTRY FOLDER: the shell's cwd; relative to the
                                                     //   workspace, or absolute; empty/"." = workspace root
  },
  "network": {
    "mode": "off",                                   // off | none | allowlist
    "log":  false,
    "mitm": false,
    "allow": ["api.anthropic.com"]
  },
  "mounts": {
    "workspace":  "rw",                              // rw | ro (the workspace mount mode)
    "confirm_rw": false,                             // prompt before every read-write mount
    "rw_allow":   ["~/out/shared"],                  // pre-approve rw sources under confirm_rw
    "read_only":  { "~/ref/standards": "/external/standards" },
    "read_write": { "~/out/shared":    "/external/shared" },
    "devices":    []                                 // host device nodes to pass through
  },
  "sandbox": {
    "ssh":     true,                                 // host SSH keys + agent
    "usb":     true,                                 // /dev/bus/usb
    "host_ca": true                                  // host extra TLS anchors
  }
}
```

### 5.0 Model selection (`model.*`, `lib/model.sh`)

`model.id` → `ANTHROPIC_MODEL`. `model.provider` sets `anthropic` (default), `bedrock`
(`CLAUDE_CODE_USE_BEDROCK=1`), or `vertex` (`CLAUDE_CODE_USE_VERTEX=1`). `model.base_url`
sets the matching `ANTHROPIC_*_BASE_URL`. `model.pass_env` forwards host variables **by
name** (so secrets never appear in argv or `--dry-run`). agentdev derives the endpoint host
(the provider default, or the host of `base_url`); under `network.mode: "allowlist"` that
endpoint must be allowed (checked with the proxy's own rules via `lib/allowcheck.py`) or the
launch aborts.

### 5.1 The entry folder (`workspace.workdir`)

The workspace always mounts at `/<dir>`. The entry folder is where the container's shell
(`bash`) starts — its working directory. This makes a **folder per working context** natural:
keep an `agentdev-config.json` and a `.envrc` in that folder, and launch the agent so it comes
up already inside it with its environment loaded.

- Resolution: empty or `"."` → the workspace root `/<dir>`; a relative path → under the
  workspace (`/<dir>/<path>`); an absolute path → used verbatim.
- When the target resolves inside the workspace mount, its **host** path is checked before
  launch, so a typo fails fast rather than dropping the shell somewhere unexpected.
- The launcher passes `-w <workdir>` and `-e AGENTDEV_WORKDIR=<workdir>`; the image's
  `/etc/bash.bashrc` `cd`s there (falling back to `$WORKSPACE`) and runs the `direnv` hook,
  so a `.envrc` in the folder is picked up (`direnv allow` once per store).

### 5.2 Network (`network.*`, `lib/net.sh`, `image/proxy.py`)

| `network.mode` | Mechanism | Reach |
|---|---|---|
| `off` (default) | No network args; podman default networking | Full internet |
| `none` | `--network none` | Nothing |
| `allowlist` | Agent joins an `--internal` podman network. A proxy sidecar from the same image joins it and a normal network. `HTTP(S)_PROXY` points the agent at the proxy. | Only `network.allow` entries, HTTP(S) only |

- Rules: `host`, `host:port`, `*.host`, `host/path`. Path rules need `network.mitm: true`
  for HTTPS, which terminates TLS with a per-run CA generated by host `openssl`.
- `network.log: true` writes `<profile>/agentdev-egress.log`, a plain tab-separated file
  you read with ordinary tools (there is no `report` subcommand).
- An empty allowlist is an error, and the model endpoint (§5.0) must be allowed.
- The networks and sidecar are removed by the EXIT trap.
- SSH/USB/CA passthrough (`sandbox.*`) is independent of `network.mode`.

---

## 6. On-disk formats

### Profile layout

A profile is a **plain folder** — the agent's whole home. **agentdev never versions it.**
If you want history, roll-back, or a remote, put the folder under git (or anything else)
yourself, entirely outside this tool; agentdev runs no version-control commands.

```
<profile>/                         ← a plain folder (agentdev never runs git on it)
├── .claude/                       → bind-mounted to /home/developer/.claude (rw)
│   ├── CLAUDE.md  settings.json   ┐  copied from template [include]
│   ├── hooks/  skills/  .mcp.json ┘
│   ├── projects/<ENC>/            ← created empty; memory/ is the mount point in remember mode
│   │   └── memory/                (empty dir; store overlays here, or stays local in named mode)
│   └── history.jsonl              ← created empty
├── .claude.json                   → bind-mounted to /home/developer/.claude.json (rw)
├── agentdev.meta.json             → provenance (below)
├── agentdev.lock                  → reproducibility pin (below)
└── .gitignore                     → secrets guard; excludes .credentials.json, policy-limits.json
```

The `.gitignore` is the one git-aware courtesy: it is written at seed time purely so that
**if** you later version the folder yourself, credentials and policy limits can never be
committed or pushed (VISION N6). It is inert in a folder you never put under git.

### `agentdev.meta.json`

```json
{
  "schema": 1,
  "agent": "claude",
  "mode": "clean",
  "created_at": "2026-10-17T12:00:00Z",
  "run_id": "2026-10-17T120000-a1b2c3",
  "template_source": "~/.agentdev/templates/default",
  "template_hash": "sha256:…",
  "workspace_basename": "myproject",
  "memory_store": null
}
```

### `agentdev.lock` (reproducibility pin — VISION N2)

```json
{
  "schema": 1,
  "image": "ghcr.io/gherlein/agentdev@sha256:…",
  "claude_code_version": "2.1.300",
  "template_hash": "sha256:…",
  "mount_set_hash": "sha256:…"
}
```

### Seeded `.claude.json` (minimal, believable, clean)

The sharpest open question (VISION §13). agentdev seeds the **smallest valid** object that
(a) presents as a brand-new install and (b) sets per-project trust per `--trust`:

```json
{
  "projects": {},
  "numStartups": 0,
  "hasCompletedOnboarding": true,
  "userID": "<random-uuid>"
}
```

- `projects` is empty **unless** `trust=workspace-only`, in which case exactly the
  container workspace key is pre-trusted and nothing else:
  ```json
  "projects": { "/myproject": { "hasTrustDialogAccepted": true } }
  ```
- Feature-flag / cache fields are intentionally omitted (a clean run re-fetches them). The
  exact field set is pinned against CLI 2.1.300 and lives in `templates/default` as a
  `claude.json.seed` fragment so it is updatable without code changes. **Verify the field
  list against the installed CLI at build time** — these fields are version-skewed.

---

## 7. The memory layer (remember mode)

Memory lives at a **deterministic** path inside `.claude`:

```
projects/<ENC>/memory/
```

where `<ENC>` is the container workspace path with separators encoded. The container
workspace is always a single top-level segment `/<DIR_NAME>` (the launcher mounts `pwd` at
`/<basename>`), so:

```
ENC = "-" + DIR_NAME, with "." replaced by "-"
# container workspace /myproject      → ENC = -myproject
# container workspace /my.app         → ENC = -my-app
```

> This encoding (replace `/` and `.` with `-`) is Claude Code's `projects/` directory
> convention, confirmed by the host memory path `…/projects/-home-gherlein-src-agentdev/`.
> Because the container workspace path is fixed and single-segment, `<ENC>` is trivial and
> stable. **Assert it at launch** (fail-closed) rather than trusting it blindly.

Mechanism:

1. Seed a clean profile as usual (fresh config, transcripts, identity).
2. Pre-create `<profile>/.claude/projects/<ENC>/memory` so the bind has a mount point.
3. Append the overlay **after** the profile mount so it lands on top:
   ```bash
   PROFILE_MOUNT+=("-v" "$MEMORY_STORE:/home/developer/.claude/projects/$ENC/memory:rw")
   register_target "/home/developer/.claude/projects/$ENC/memory" "memory store $MEMORY_STORE"
   ```
4. `register_target` guarantees no external `-rw` mount collides with it.

Properties: the store is its own plain folder under `memory_root/<name>`, shareable across
repos; agentdev does not version it (put it under git yourself if you want memory history).
`profile.mode: clean` with no memory store configured mounts **no** memory layer — clean
stays clean; `remember` is "amnesiac about conversations, but keeps what it learned."

---

## 8. Mode mechanics, precisely

| Step | clean | remember | named |
|---|---|---|---|
| Resolve path | `clean_root/<run-id>` | `clean_root/<run-id>` | `profiles_root/<name>` |
| Seed? | always | always | only if absent |
| Memory mount | none | `memory_root/<store>` overlay | in-profile (persists naturally) |
| Lock | n/a (unique run-id) | n/a | `flock` — refuse 2nd concurrent launch |
| Cleanup on exit | `rm -rf` unless `profile.keep` | `rm -rf` home; keep store | keep |

**Clean-mode guarantees** (VISION §5) are enforced structurally: a fresh `clean_root`
dir with no `projects/*/*.jsonl`, no `memory/`, an empty `history.jsonl`, a fresh
`.claude.json`, no `.credentials.json` seeded (api-key-env), template-only config,
removed on exit. The exit trap `rm -rf`s on *any* exit path (including signals) so a
crash leaves at most a stale dir that `gc` sweeps.

---

## 9. Auth & trust

**`auto` is the default** — it detects what this host uses natively and just does that,
resolving at launch to one of the concrete modes below:

1. `ANTHROPIC_API_KEY` set in the environment → **api-key-env**.
2. else a **named profile** with a readable host `~/.claude/.credentials.json` →
   **inherit-credentials**.
3. else → **interactive**.

The resolution is printed (`Auth: auto -> <mode>`). `auth.mode` in the config forces a
specific mode. A non-Anthropic `model.provider` resolves to **provider-env** (credentials
via `model.pass_env`; `auth.mode` must be `auto`).

- **api-key-env.** Forward `ANTHROPIC_API_KEY` into the container **by name** (`-e
  ANTHROPIC_API_KEY`, so the value never appears in argv or `--dry-run`) and seed no
  `.credentials.json`; fail-closed if the key is unset.
- **inherit-credentials** (named profiles only). Copy the host's subscription
  `~/.claude/.credentials.json` into the profile once, mode `600`, gitignored — **and**
  merge the host's claude.ai account linkage (`oauthAccount`, `hasAvailableSubscription`,
  `userID`) from `~/.claude.json` into the profile's seeded `.claude.json` (an allowlist of
  non-secret fields — no tokens, no project history). The token alone is inert: Claude Code
  only treats a session as a signed-in subscription when the account block is present too,
  so copying the token *and* the account is what actually reuses the login (connectors,
  managed settings, org policy). Refused for clean/remember: a secret is never copied into a
  throwaway home (preserves the clean-room guarantee). Caveat: this reconstitutes a sign-in
  the host login already has; it cannot add an OAuth scope the host token lacks (a host
  login "missing the `user:profile` scope" stays missing it — sign in inside the profile to
  mint a fresh, fully-scoped token, which persists in the named profile).
- **interactive.** Forward nothing; log in inside the container. The profile's `.claude` is
  bind-mounted `:rw`, so the login writes `.credentials.json` into the profile — lasting for
  a named profile, ephemeral (discarded) for clean/remember.

The key is only forwarded when the effective mode is `api-key-env`, so a stray
`ANTHROPIC_API_KEY` never leaks into an inherit/interactive run.

**Trust.** `workspace.trust` only affects seeding. `workspace-only` pre-seeds trust for
exactly the workspace path in `.claude.json` (§6). `skip-permissions` and `prompt` both
seed nothing, so they produce identical profiles. agentdev never adds
`--dangerously-skip-permissions` to an interactive `claude`. The user runs `claude`
or `clauded` in the shell. A `--prompt`/`prompt.file` run always passes
`--dangerously-skip-permissions`, regardless of `workspace.trust`. The value is validated
against its enum by the schema.

---

## 10. The agent abstraction (why Claude-only doesn't paint us in)

Only Claude Code is wired today, but the seams for other agents are placed at low cost:

- `agent.name` is validated to `claude` by the schema and recorded in
  `agentdev.meta.json`. Admitting another agent is a schema change plus a per-agent table.
- The profile is *"the home dir(s) for this agent"*; for `claude` that's `.claude/` +
  `.claude.json`. Adding an agent is: (a) its `include` list, (b) its home path(s), (c) its
  memory path convention, (d) its auth env, (e) its headless prompt command, (f) its model
  env. Nothing in the mount plan, seeding skeleton, folder lifecycle, or CLI changes shape.
- **Not done yet:** `PROFILE_MOUNT` is hardcoded to `.claude` + `.claude.json`
  (`agentdev` `launch()`), and the `--prompt` command is hardcoded to `claude`. The
  intended per-agent table has not been built. The image already ships `opencode` and
  `omp` as tools, but agentdev does not manage their homes. Model selection (§5.0) is
  Claude-specific (the `ANTHROPIC_*` / `CLAUDE_CODE_*` env vars).

The design constraint: **implement Claude concretely, but never behind an interface the
next agent would have to break.**

---

## 11. Scope boundary

**In:** the self-contained image (`Containerfile` + `entrypoint.sh`, built with
`make build`); the single, strict, fail-closed config file (`-c` / `$AGENTDEV_CONFIG` /
`./agentdev-config.json`); the minimal CLI (`--dry-run`, `-c`, `--prompt`, `-- command`);
clean / remember / named modes; model selection (id / provider / base_url / forwarded
credentials, with the allowlist interlock); `copy` seeding with linting; plain-folder
profiles & memory stores (managed with ordinary tools — no subcommands, no version control;
a `.gitignore` secrets guard is the only concession); `auto` / api-key-env /
inherit-credentials / interactive auth; trust seeding; network `off` / `none` / `allowlist`
with egress logging and an optional MITM tier; the `flock` + live-container + fixed-name
concurrency guard; `meta.json` / `lock`.

**Deliberately out of scope** (cut, not deferred — ordinary files, git, and a shell cover
them): workspace copy-on-write / patch-review, `overlay-ro` / composable templates, fleet /
best-of-N / fan-out, cost accounting, and any profile/memory/report/doctor/init/build
subcommand.

**Next:** other agents (generalize the per-agent table above). The config, mount plan,
seeding, and lifecycle are already agent-shaped.

---

## 12. Open decisions (design-level, to settle before/while building)

1. **Image base & Claude Code install method** — Debian slim + npm global install of the
   CLI, pinned by version; decide whether to bake a known-good CLI version into the image
   or install at build from a pinned npm tag (lock records whichever resolves).
2. **Exact `.claude.json` seed field set** for 2.1.300 — pin in `templates/default` and add
   a check that warns when the installed CLI's schema has moved. (VISION §13.)
3. **`<ENC>` assertion** — compute and assert at launch; decide the failure message when a
   future CLI changes the encoding.
4. **Folder provenance without version control** — agentdev does not version folders; is
   `agentdev.meta.json` + `agentdev.lock` enough provenance, or do we want a lightweight
   append-only run log (not git) for named profiles?
5. **Launching claude vs. bash** — partly settled: `--prompt <file>` launches the agent
   headless. Interactive runs still open `bash`. Open: should the config choose this?
6. **Lint strictness** — how hard to fail on a template whose `settings.json` is valid JSON
   but schema-unknown to the installed CLI.

---

*North star (unchanged from the vision): the agent's entire self — what it was told,
everything it remembers, and everything it did — is one plain folder you control. What you
do with it — version it, archive it, wipe it — is yours to decide, outside this tool.*
