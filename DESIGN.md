# agentdev — Phase 1 Technical Design

> Companion to [`VISION.md`](./VISION.md). This document specifies **Phase 1** (Claude
> Code only): the component breakdown, the CLI surface, the on-disk formats, and the two
> algorithms that matter — **seeding** a profile and building the **mount plan** — in
> enough detail to implement. It is deliberately scoped: everything the vision marks
> Phase 2/3 (network allowlist, cow/patch workspace, `report`, overlay templates, fleet,
> multi-agent) is out of scope here and called out in §11.

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
`python3` (for TOML parsing, already a Claude Code prerequisite), and the agentdev image
it builds and publishes.

```
agentdev (this repo)
├── agentdev                     ← the launcher (bash); the only entry point
├── lib/
│   ├── mounts.sh                ← OUR mount-collection library (union grammar, collisions, CA, SSH)
│   ├── profile.sh               ← resolve / create / lock / fork / gc a profile (plain folders)
│   ├── seed.sh                  ← template → profile (lint, copy, scaffold, .claude.json)
│   ├── memory.sh                ← resolve a memory store; compute the deterministic path
│   ├── config.sh                ← layered TOML/flag resolution (§5)
│   └── meta.sh                  ← write & read agentdev.meta.json / agentdev.lock
├── image/
│   ├── Containerfile            ← builds ghcr.io/gherlein/agentdev (hardened, non-root)
│   └── entrypoint.sh            ← UID/GID remap, host-home symlink, CA rebuild, gosu exec
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
- The **`opencode`** and **`omp`** agents (present as tools; agentdev Phase 1 still only
  *manages profiles for* Claude — see §10).
- `ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]`, default `CMD ["bash"]`.

The image is pinned **by digest** in config and in every profile's `agentdev.lock`, so a
run is reproducible regardless of tag movement (VISION N2). The Claude Code version the
installer resolves is captured into the lock at seed time (§6).

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

Authored fresh. Provides the same *grammar* localdev popularized, as agentdev's own code:

- `collect_mounts` — single entry point; unions three sources (CLI `-ro`/`-rw`/bare args,
  the `AGENTDEV_MOUNTS` env var, and `./.agentdev-mounts.toml`) into `VOLUME_MOUNTS` /
  `DEVICE_MOUNTS` / `MOUNTS_CONTENT`, aborting on any file error.
- `register_target` — claims one container-side target per source; a second claim on the
  same target is **always fatal** (collision detection). Reserves the workspace and the
  managed agent paths up front.
- `resolve_path` — normalizes/validates a host source (realpath; must exist & be readable).
- `collect_host_ca_mount` — bind the host's extra TLS anchors read-only + set
  `NODE_EXTRA_CA_CERTS`.
- `handle_init_flag` — `agentdev init` writes a starter `.agentdev-mounts.toml`.

Grammar: `source = destination`, where destination is an absolute container path, a path
relative to the workspace, or `&` to mirror a relative source's layout. Relative paths and
`&` are portable/committable; absolute host paths are host-specific.

### 2.4 Control flow of one launch

```
agentdev [flags] [mount-args...] [-- command...]
  │
  ├─ parse flags, resolve config (CLI > ./.agentdev.toml > ~/.agentdev/config.toml > defaults)
  ├─ doctor preflight: ANTHROPIC_API_KEY?, podman?, agentdev image digest present?, template readable?
  ├─ resolve MODE → resolve PROFILE path (clean_root/<run-id> | profiles_root/<name>)
  ├─ if profile absent OR clean:  seed.sh   (lint template, copy, scaffold, .claude.json, .gitignore guard)
  ├─ if remember:                 memory.sh (resolve store, compute $ENC, ensure mount point)
  ├─ lock the profile (flock)                        # named mode: refuse 2nd concurrent use
  ├─ source lib/mounts.sh; collect_mounts "agentdev" "$DIR_NAME" "$@"; collect_host_ca_mount
  ├─ build PROFILE_MOUNT (+ MEMORY_MOUNT); register_target the memory path
  ├─ assemble podman argv (workspace, userns, ssh, ca, api-key, HOST_* env, profile)
  │     --dry-run prints the settled config + seed plan + full mount plan and EXITS here
  ├─ podman run ... ghcr.io/gherlein/agentdev@sha256:…  (bash by default, or trailing -- command)
  └─ on exit (trap): rm -rf if clean & !--keep ; named/kept folders are left as-is
```

---

## 3. Component breakdown

| Component | File | Responsibility |
|---|---|---|
| **Launcher** | `agentdev` | Arg parse, orchestrate, assemble `podman run`, exit trap |
| **Image** | `image/Containerfile` | Hardened non-root image with Node + Claude Code CLI |
| **Entrypoint** | `image/entrypoint.sh` | UID/GID remap, host-home symlink, CA rebuild, gosu exec |
| **Mount library** | `lib/mounts.sh` | External-mount union, collisions, CA, SSH, `init` |
| **Config resolver** | `lib/config.sh` | Merge CLI / per-project / user / defaults into one settled config |
| **Profile manager** | `lib/profile.sh` | Resolve path per mode, create dir, `flock`, `fork`, `gc`, `rm` (plain folders) |
| **Seeder** | `lib/seed.sh` | Lint template, copy `include`, build runtime scaffold + `.claude.json`, `.gitignore` secrets guard |
| **Memory manager** | `lib/memory.sh` | Resolve store under `memory_root`, compute `$ENC`, create mount point |
| **Meta/lock writer** | `lib/meta.sh` | `agentdev.meta.json`, `agentdev.lock` (image digest, CLI ver, template hash) |

The launcher sources the `lib/*.sh` files; shared state is a small set of globals
(`VOLUME_MOUNTS`, `DEVICE_MOUNTS`, `MOUNTS_CONTENT`, `MOUNT_ERRORS`, plus agentdev's
`PROFILE`, `MODE`, `ENC`, `MEMORY_STORE`).

---

## 4. CLI surface & flag → behavior mapping

```
agentdev [MODE] [OPTIONS] [MOUNT-ARGS...] [-- COMMAND...]
```

### Modes (mutually exclusive; default from `[profile].default_mode`, built-in `clean`)

| Flag | Mode | Profile location | Config | Memory | History | Lifetime |
|---|---|---|---|---|---|---|
| `--clean` | clean room | `clean_root/<run-id>` | seeded | fresh | fresh | removed on exit (`--keep` retains) |
| `--remember [store]` | remember | `clean_root/<run-id>` | seeded | **persistent** (mounted) | fresh | home removed; store persists |
| `--profile <name>` | named | `profiles_root/<name>` | seeded once, drifts | persistent | persistent | kept |

### Options

| Flag | Effect | Phase |
|---|---|---|
| `--template <path>` | Override `[template].source` for this run | 1 |
| `--auth <mode>` | `auto` \| `api-key-env` \| `interactive` \| `inherit-credentials` (default from config) | 1 |
| `--login` | Shorthand for `--auth interactive` (Claude Pro/Max subscription login) | 1 |
| `--keep` | Clean mode: don't delete the profile; print its path | 1 |
| `--reseed` | Re-apply template **config** over an existing profile; leave memory/history | 1 |
| `--trust <mode>` | `skip-permissions` \| `workspace-only` \| `prompt` (default from config) | 1 |
| `--dry-run` | Print the settled config, seed plan, and full mount plan; **do not launch** | 1 |
| `-ro <path>` / `-rw <path>` / `<path>` | External mounts (handled by `lib/mounts.sh`) | 1 |
| `-- <command...>` | Run this instead of interactive `bash` (e.g. `-- claude -p "…"`) | 1 |
| `--net=allowlist`, `--cow-workspace`, `--patch-only`, `--budget`, `--fan-out N` | — | **2/3** |

### Subcommands (management surface)

| Command | Phase 1 behavior |
|---|---|
| `agentdev profiles ls\|show\|new\|rm\|fork\|gc` | Manage `profiles_root`; `gc` sweeps crashed `clean_root` leftovers |
| `agentdev memory ls\|new\|rm` | Manage `memory_root` stores (plain folders) |
| `agentdev doctor` | Check API key, podman, image digest, template readability + lint |
| `agentdev init` | Write a starter `.agentdev-mounts.toml` in the launch directory |
| `agentdev build` | Build/tag the agentdev image locally from `image/Containerfile` |
| `agentdev report`, `--net`, cow/patch | **Phase 2** |

**Default command.** The container's default command is interactive `bash`; the user runs
`claude` inside. `-- <command>` runs a command instead, which is how automation and
`--fan-out` (later) drive it:
`agentdev --clean -- claude --dangerously-skip-permissions -p "fix #123"`.

---

## 5. Configuration & resolution

TOML. Resolution order (first found wins per key; **CLI always wins**):

1. CLI flags
2. `./.agentdev.toml` (per-project, committable; relative paths + `&` only)
3. `~/.agentdev/config.toml` (user; host-specific absolute paths live here)
4. Built-in defaults

External mounts (`[mounts.*]`, `-ro`/`-rw`, `AGENTDEV_MOUNTS`) combine as a **union**. The
**profile**, **memory store**, and **template** each resolve to exactly one authoritative
value — one agent home per run. Any error in the authoritative config or template
**aborts before the container starts** (fail-closed).

```toml
# ~/.agentdev/config.toml
[agent]
name  = "claude"                                     # Phase 1: the only value
image = "ghcr.io/gherlein/agentdev@sha256:…"         # agentdev's own image, pinned by digest

[profile]
profiles_root = "~/.agentdev/profiles"
clean_root    = "~/.cache/agentdev/clean"            # tmpfs-friendly (Phase 2)
memory_root   = "~/.agentdev/memory"
default_mode  = "clean"                              # clean | remember | profile

[template]
source   = "~/.agentdev/templates/default"
strategy = "copy"                                   # overlay-ro is Phase 2
include  = ["CLAUDE.md", "settings.json", "hooks/", "skills/", ".mcp.json", "plugins.toml"]

[auth]
mode = "auto"                                       # auto | api-key-env | interactive | inherit-credentials

[workspace]
isolation = "mount"                                 # cow | patch-only are Phase 2
trust     = "skip-permissions"                      # skip-permissions | workspace-only | prompt

[mounts.read-only]
"~/ref/standards" = "/external/standards"
[mounts.read-write]
"~/out/shared"    = "/external/shared"
```

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

The sharpest open question (VISION Q1). Phase 1 seeds the **smallest valid** object that
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
A store may be mounted `:ro` for read-only team memory (Phase 2 layering of a writable store
on top). `--clean` *without*
`--remember` mounts **no** memory layer — clean stays clean.

---

## 8. Mode mechanics, precisely

| Step | clean | remember | named |
|---|---|---|---|
| Resolve path | `clean_root/<run-id>` | `clean_root/<run-id>` | `profiles_root/<name>` |
| Seed? | always | always | only if absent |
| Memory mount | none | `memory_root/<store>` overlay | in-profile (persists naturally) |
| Lock | n/a (unique run-id) | n/a | `flock` — refuse 2nd concurrent launch |
| Cleanup on exit | `rm -rf` unless `--keep` | `rm -rf` home; keep store | keep |

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

The resolution is printed (`Auth: auto -> <mode>`). `--auth <mode>` / `--login` force a
specific mode.

- **api-key-env.** Forward `ANTHROPIC_API_KEY` into the container (`-e ANTHROPIC_API_KEY=…`)
  and seed no `.credentials.json`; fail-closed if the key is unset.
- **inherit-credentials** (named profiles only). Copy the host's subscription
  `~/.claude/.credentials.json` into the profile once, mode `600`, gitignored — so "it just
  works" with the Claude Pro/Max login you already have. Refused for clean/remember: a
  secret is never copied into a throwaway home (preserves the clean-room guarantee).
- **interactive.** Forward nothing; log in inside the container. The profile's `.claude` is
  bind-mounted `:rw`, so the login writes `.credentials.json` into the profile — lasting for
  a named profile, ephemeral (discarded) for clean/remember.

The key is only forwarded when the effective mode is `api-key-env`, so a stray
`ANTHROPIC_API_KEY` never leaks into an inherit/interactive run.

**Trust.** Default `skip-permissions`: when launching `claude`, pass
`--dangerously-skip-permissions`. `workspace-only` instead pre-seeds trust for exactly the
workspace path in `.claude.json` (§6) and skips the dangerous flag — the clean-room-minimal
choice. `prompt` seeds nothing and lets the trust dialog appear.

---

## 10. The agent abstraction (why Phase 1 doesn't paint us in)

Phase 1 is Claude Code only, but the seams for other agents are already placed, at **zero
Phase-1 cost**:

- `[agent].name` exists and is read (only `claude` is valid now).
- The profile is defined as *"the home dir(s) for this agent"*; for `claude` that's
  `.claude/` + `.claude.json`. Adding an agent is: (a) its `include` list, (b) its home
  path(s), (c) its memory path convention, (d) its auth env var. Nothing in the mount
  plan, seeding skeleton, folder lifecycle, or CLI changes shape.
- `PROFILE_MOUNT` is built from a small per-agent table rather than hardcoded, so Phase 3
  swaps `.claude`→`.opencode`/`.pi`/`.omp`/`.kit` without touching the launcher body. The
  image may need per-agent CLIs installed; `[agent].image` lets each agent pin its own.

This is the single most important design constraint on Phase 1: **implement Claude
concretely, but never behind an interface the next agent would have to break.**

---

## 11. Phase 1 scope boundary

**In:** the self-contained image (`Containerfile` + `entrypoint.sh`) and `agentdev build`;
our own `lib/mounts.sh` (union grammar, collisions, CA, SSH, `init`); clean / remember /
named modes; `copy` seeding with linting; plain-folder profiles & memory stores (`fork`,
`gc`, `rm` — no version control; versioning is left entirely to the user, outside the tool);
a `.gitignore` secrets guard; `auto` auth detection (api-key-env / inherit-credentials /
interactive); trust seeding; `profiles`/`memory`/`doctor`/`init`/`--dry-run`; `flock`
concurrency guard; `meta.json`/`lock`.

**Deferred (Phase 2):** `--net=allowlist` + egress logging; `--cow-workspace` /
`--patch-only`; tmpfs clean rooms; `report` (cost/cache/tools) + `--budget`; `overlay-ro`
templates; read-only/layered team memory.

**Deferred (Phase 3):** `--fan-out` fleet/best-of-N; composable template layers;
multi-agent (`--agent`, generalized home-path table, per-agent image install).

---

## 12. Open decisions (design-level, to settle before/while building)

1. **Image base & Claude Code install method** — Debian slim + npm global install of the
   CLI, pinned by version; decide whether to bake a known-good CLI version into the image
   or install at build from a pinned npm tag (lock records whichever resolves).
2. **Exact `.claude.json` seed field set** for 2.1.300 — pin in `templates/default` and add
   a `doctor` check that warns when the installed CLI's schema has moved. (VISION Q1.)
3. **`<ENC>` assertion** — compute and assert at launch; decide the failure message when a
   future CLI changes the encoding.
4. **Folder provenance without version control** — agentdev does not version folders; is
   `agentdev.meta.json` + `agentdev.lock` enough provenance, or do we want a lightweight
   append-only run log (not git) for named profiles?
5. **Launching claude vs. bash** — keep bash default and rely on `-- claude …` for
   automation, or add a `--exec claude` convenience with trust flags wired in automatically?
6. **Lint strictness** — how hard to fail on a template whose `settings.json` is valid JSON
   but schema-unknown to the installed CLI.

---

*North star (unchanged from the vision): the agent's entire self — what it was told,
everything it remembers, and everything it did — is one plain folder you control. What you
do with it — version it, archive it, wipe it — is yours to decide, outside this tool.*
