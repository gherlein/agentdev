# agentdev — Vision

> An isolated, containerized environment for running coding agents where **all of the
> agent's "self"** — its authored config, its generated history, and its learned memory —
> lives in a single, swappable folder on the host. Run it as a **clean room**
> (a brand-new user with no past), as a **remembering agent with clean history** (keeps
> what it learned, forgets the chatter), or against a **named profile** that carries
> everything forward. Optionally isolate the *code* too, and lock down the network, so a
> run in dangerous mode is safe end to end.
>
> **agentdev is agent-agnostic by design.** The abstraction — a profile is "the home
> dir(s) for *this* agent" — generalizes across every agent whose state lives in a
> well-known home. **Phase 1 supports Claude Code only; other agents are the very next
> thing we add** (§16). The name reflects where this is going, not a limitation of where
> it starts.

---

## 1. Why this exists

[`localdev`](../localdev) already gives us a safe, feature-rich container for running
Claude Code in `--dangerously-skip-permissions` mode without exposing the host
filesystem. It works well, but it makes one deliberate choice that `agentdev` wants to
invert:

> **localdev bind-mounts the host's real `~/.claude` (read-write) straight into the
> container.** The agent inside the container *is* you. It reads your global `CLAUDE.md`,
> writes to your real transcript history, inherits your credentials, your memory, your
> per-project trust decisions, and your prompt log — and leaves all of that changed on
> the host when it exits.

That is exactly right for "I am me, working on my project, with my usual setup." It is
exactly wrong for several things we increasingly want:

- **A true clean room.** Run a task "as if" the container were a brand-new user on the
  host, with zero history, zero memory, zero prior context — a reproducible one-shot
  environment whose entire footprint is captured in one place.
- **Isolated, swappable memory.** Keep the agent's history and memory in a folder I can
  name, fork, archive, or throw away — and version myself with git if I want to — without
  entangling it with my daily-driver `~/.claude`.
- **Remember without the baggage.** Keep what the agent *learned* across runs while
  starting each session with a clean transcript — no stale context, no compaction
  baggage, lower cost.
- **Safety end to end.** When I run in dangerous mode, isolate not just the agent's home
  but optionally the *code* it touches and the *network* it can reach.
- **Reproducibility and auditability.** Seed every run from a known-good config
  *template* and pin the exact image and CLI build, so two runs start identically and
  any divergence lives entirely in one captured profile folder.

`agentdev` is **built fresh and stands alone** — it ships its own container image, its own
entrypoint, and its own mount logic, with no dependency on localdev's code, image, or
launchers. It adopts the hardening localdev proved out — a hardened image, a non-root
user, `--userns=keep-id` ownership mapping, external mounts, TLS trust passthrough, SSH
agent forwarding — and **implements all of it itself**, while changing **one thing at the
core**: the agent's home is no longer your host `~/.claude`. It is a **profile folder**
that `agentdev` creates fresh,
re-uses by name, or layers memory into — and, as options, it can wrap the workspace and
the network in isolation too.

---

## 2. The core idea: config, runtime, and memory — and the profile that holds them

Everything Claude Code keeps under `~/.claude/` (and the sibling `~/.claude.json`) is
one of a few kinds of thing. This split is the entire foundation of the design. Note
especially that **runtime state is not one bucket** — *transcripts/history* ("what
happened") and *memory* ("what was learned") are different, and agentdev treats them as
independently mountable layers. That separation is what unlocks the middle mode in §3.

| Plane | What it is | Examples | Where agentdev gets it |
|---|---|---|---|
| **Config (authored)** | Files a human writes to shape behavior | `CLAUDE.md`, `settings.json`, `settings.local.json`, `hooks/`, personal `skills/`, `.mcp.json`, `plugins.toml` | **Seeded from a template** at profile creation |
| **Memory (learned)** | What the agent accumulates *as knowledge* | `projects/<dir>/memory/`, authored-over-time drift in `CLAUDE.md` | A **memory layer** that can persist independently of transcripts |
| **History (happened)** | The running record of sessions | `projects/<dir>/*.jsonl` transcripts, `history.jsonl`, `file-history/`, `sessions/`, `session-env/`, `state/`, `jobs/`, `shell-snapshots/`, `paste-cache/` | Accumulates in the profile; kept or wiped per mode |
| **Secrets** | Auth material | `.credentials.json`, `policy-limits.json` | **Never copied into a clean room**; auth comes from a forwarded API key (§9) |

(This taxonomy follows a file-by-file audit of which files Claude Code authors, which it
generates, and which are sensitive, verified against Claude Code CLI 2.1.300. Memory lives per-project under
`projects/<encoded-dir>/memory/`; because the workspace path is fixed for a given
launch, that encoded path is deterministic — so agentdev can mount a persistent memory
directory *into* an otherwise-clean profile at exactly the right place.)

### The profile

A **profile** is a single host directory that holds a complete, self-contained agent
home. It is a **plain folder** — agentdev never versions it (§11). If you want history,
put it under git (or anything else) yourself. Its layout mirrors the slice of a home
directory Claude Code actually uses:

```
<profile>/                      ← a plain folder; agentdev runs no version control on it
├── .claude/                    → mounted to ~/.claude inside the container
│   ├── CLAUDE.md               ┐
│   ├── settings.json           │  authored config, seeded from the template
│   ├── hooks/  skills/         ┘  (then free to drift)
│   ├── projects/<enc-dir>/
│   │   ├── *.jsonl             ← transcripts (history layer)
│   │   └── memory/             ← MEMORY LAYER — independently mountable (§7)
│   ├── history.jsonl           ┐
│   ├── file-history/ sessions/ │  history layer — generated runtime state
│   └── jobs/ state/ ...        ┘
├── .claude.json                → mounted to ~/.claude.json (identity, per-project map)
├── agentdev.meta.json         → template used, created-at, mode, agent
└── agentdev.lock              → pinned image digest + CLI version + template hash (§12)
```

Mounting this profile — instead of the host's real `~/.claude` — is the whole trick.
The agent gets a complete, believable home that is *this folder and nothing else*, so
its entire life story is captured in one place we can seed, fork, reuse, or delete — and
that you are free to version yourself, outside the tool, if you want history.

---

## 3. Three modes over one abstraction

All three modes are the same mount with different answers to *where the profile lives,
whether it survives, and which layers are fresh*:

| Mode | Flag | Config | Memory | History | Profile lifetime |
|---|---|---|---|---|---|
| **Clean room** | `--clean` | seeded from template | **fresh** | **fresh** | throwaway (kept with `--keep`) |
| **Remember, clean history** | `--remember [store]` | seeded from template | **persistent** (mounted) | **fresh** | throwaway home + persistent memory store |
| **Named / persistent** | `--profile <name>` | seeded once, then drifts | persistent | persistent | kept under `profiles_root` |

- **Clean room** — a genuine brand-new user: no prior transcripts, no memory, a fresh
  `.claude.json`, API-key auth with no credential file, discarded on exit. The strict
  guarantees are spelled out in §5.
- **Remember, clean history** — the everyday sweet spot. A clean-room home (fresh
  transcripts, fresh identity) with a **persistent memory layer** mounted in (§7). The
  agent keeps what it learned across runs but never carries stale conversation context
  or compaction debris, which also keeps cost down.
- **Named / persistent** — resolve (or first-time create and seed) a profile under
  `profiles_root`; thereafter reuse it as-is so everything accumulates. The classic
  "isolated but fully re-usable" case.

The only real differences between modes are *where* the profile lives, *whether* it
survives the run, and *which layers are fresh vs. mounted*. Seeding, mounting, and the
container are identical.

---

## 4. What a session looks like

```bash
# Clean room: fresh agent, no history, no memory, discarded on exit.
cd ~/src/my-project
agentdev --clean

# Remember what you learn, but start each session with a clean transcript.
agentdev --remember                       # uses the default memory store
agentdev --remember research              # a named memory store, shared across repos

# Fully persistent named profile — remembers everything, carries history forward.
agentdev --profile research

# Clean room, but keep the profile afterward so I can inspect what it did (and version
# it myself if I want — agentdev leaves that to me).
agentdev --clean --keep

# Branch a profile's memory, try a risky approach, keep or discard it.
agentdev profiles fork research experiment
agentdev --profile experiment

# Isolate the CODE too: agent works in a throwaway copy, emits a patch I apply.
agentdev --clean --patch-only

# Lock the network down to Anthropic + package registries for an untrusted task.
agentdev --clean --net=allowlist

# Seed from a specific template; add reference material and a shared output dir.
agentdev --clean --template ~/configs/minimal-claude \
          ~/ref/api-docs -rw ~/out/generated
```

As with localdev, the **current working directory is the read-write workspace** at
`/<directory-name>` and is the only project code the agent sees. What changes is that
the agent's *home* is now a profile, not your personal `~/.claude` — and, optionally,
that the workspace and network are isolated too (§10, §11).

---

## 5. Clean mode, precisely

A clean-room run guarantees:

1. **No prior conversation** — no `projects/*/*.jsonl` from any other run.
2. **No prior memory** — no `projects/*/memory/` carried in (unless `--remember` adds a
   memory layer, which is then the only persistent thing — see §7).
3. **No prior prompt log** — a fresh, empty `history.jsonl`.
4. **No inherited identity or trust** — a fresh `.claude.json`: new identity, empty
   per-project trust/metrics map, no `hasTrustDialogAccepted` from past runs (§9).
5. **No persistent credentials on disk** — auth is a forwarded `ANTHROPIC_API_KEY`; no
   `.credentials.json` is copied in, and none the run writes survives (the profile is
   discarded; with tmpfs it never hits disk — §12).
6. **Only the authored template as a starting point.**
7. **Discarded on exit** — overridable with `--keep`, which prints the retained path.

The mental test: *a clean-room run is indistinguishable from a brand-new user who just
installed Claude Code, dropped in the standard config, and ran one task.* Two clean runs
of the same prompt against the same repo differ only by model nondeterminism, never by
leftover state.

A clean room still gets everything that is about *isolation, not deprivation*: the
workspace, declared external mounts, network, SSH agent forwarding, and host TLS trust.

---

## 6. Seeding: how the template becomes a profile

Two strategies, chosen per `[template].strategy`:

- **`copy` (default).** At profile creation, copy the template's `include` list into
  `<profile>/.claude/`, create empty runtime scaffolding (`projects/`, `history.jsonl`,
  a minimal valid `.claude.json`), and let everything be writable thereafter. The profile
  is a real, self-contained home you can `tar`, move, or (if you put it under git
  yourself) push to a remote.
- **`overlay-ro` (later).** Mount the template read-only and layer a writable upper dir
  (overlayfs, or `:ro` template + `:rw` runtime subdirs) so the authored baseline is
  physically immutable and *only* generated state lives in the writable layer. Enforces
  "config vs. runtime" rather than relying on convention; more moving parts (rootless
  overlay quirks), hence a later phase.

Named profiles are seeded **once** on first creation and never silently re-seeded, so
your drift survives. `--reseed` re-applies the template over an existing profile's
*config* files while leaving memory and history intact — useful when the template
improves. Templates are **composable** (base + overlays, stow-style): e.g.
`base-claude` + `python-project` + `company-standards` (§12). Seeding **lints** the
template (hooks executable, `settings.json` schema-valid, skills well-formed) and fails
closed, matching localdev's philosophy.

---

## 7. The memory layer: clean history, persistent memory

This is the mechanism behind the middle mode in §3, and the sharpest expression of the
project's goal of isolating *memory* specifically.

Because memory lives at a **deterministic path** — `projects/<encoded-workspace>/memory/`
for the launch directory, plus any global memory convention — agentdev can:

1. build an otherwise-clean profile (fresh config, fresh transcripts, fresh identity),
   and
2. bind-mount a **persistent memory store** into the memory path(s), leaving the rest of
   the profile ephemeral.

The result: the agent writes and reads real, durable memory, but every session's
transcript starts empty. Properties worth calling out:

- **A memory store is its own named, portable folder** (`memory_root/<name>`),
  independent of any one profile — so memory can be shared across repos and across
  modes. It is a plain folder; agentdev does not version it.
- **Read-only team memory.** A store can be mounted read-only (e.g. cloned from a team
  git repo) so the agent *reads* shared knowledge but writes personal memory into a
  separate writable store layered on top.
- **History is yours to keep.** If you want "what did the agent learn, and can I undo
  that?", put the store under git yourself — then ordinary `git diff` / `git log` /
  `git revert` answer it. agentdev deliberately wraps none of this.
- **Clean rooms stay clean.** `--clean` without `--remember` mounts *no* memory layer;
  `--clean --remember <store>` is precisely "amnesiac about conversations, but keeps
  what it learned."

---

## 8. Authentication and trust in an isolated home

- **`auto` (default) → detect what the host uses and do that.** At launch agentdev
  resolves: an `ANTHROPIC_API_KEY` in the environment → API-key env; else a **named
  profile** with a readable host subscription login → inherit it; else interactive login.
  So `agentdev --profile me` "just works" with whatever you already use on this machine.
- **API key env (`api-key-env`).** Forward `ANTHROPIC_API_KEY` into the container and seed
  **no** `.credentials.json`. Nothing secret is written to a folder that might be kept.
- **Inherit credentials (`inherit-credentials`), named profiles only.** Copy the host's
  subscription `~/.claude/.credentials.json` into the profile once (mode `600`, gitignored)
  so a Claude Pro/Max login carries in without an env var. The secret now lives in that
  folder — treat the whole profile as sensitive (`chmod 700`); never push it to a shared
  remote. Refused for clean/remember: a secret is never copied into a throwaway home.
- **Interactive (`interactive`).** Forward nothing; log in inside the container
  (`--login` is the shorthand). Lasting for a named profile, ephemeral for clean/remember.

**Trust-dialog friction.** A fresh `.claude.json` leaves per-project
`hasTrustDialogAccepted` unset, so a clean room would prompt to trust the workspace.
Default resolution: run with `--dangerously-skip-permissions` (localdev's default),
with an opt-out that instead **pre-seeds trust for exactly the workspace path and
nothing else** — the clean-room-minimal choice.

---

## 9. Isolating the workspace (the code), not just the home

Today only `~/.claude` is isolated; the workspace is still your real working tree
mounted read-write. The logical completion of the clean-room idea is to isolate the code
the agent touches:

- **`--cow-workspace`** — the agent works in a copy-on-write clone of the repo; you
  review and then accept (sync back) or discard. Even read-write experiments never touch
  your real tree until you say so.
- **`--patch-only` / `--ro-workspace`** — workspace mounted read-only; the agent
  produces a diff that `agentdev` surfaces for you to apply on the host. The safest
  posture for an untrusted or exploratory task.

This is what turns "dangerous mode, but my home is safe" into "dangerous mode, and my
code and home are both safe." Combined with §10 it closes the remaining escape paths.

---

## 10. Network & egress isolation

agentdev offers isolated vs. host networking, plus a third, tighter tier for clean rooms
and untrusted tasks:

- **`--net=allowlist`** (implemented) — only an allowlist of destinations is reachable,
  via a filtering proxy sidecar on an internal (no-egress) network; everything else is
  refused. This closes the exfiltration path that "isolated filesystem, open network"
  leaves open. Domain-level by default; an opt-in MITM tier filters per-URL. `--net=none`
  is the fully-offline variant.
- **Egress logging** (implemented) — the proxy records what the run contacted, and
  `agentdev report <profile>` shows that network footprint. An auditable answer to
  "where did this agent talk to?"
- The companion **`--eval`** preset bundles this with confirm-rw, a read-only workspace,
  api-key auth and no SSH for evaluating skills (see `docs/user-guide.md` §13).

Default remains standard isolated/host networking; the allowlist is opt-in, and the
natural companion to `--clean --patch-only` for "run this prompt I don't fully trust."

---

## 11. Folder lifecycle and reproducibility

Profiles and memory stores are **plain folders**. agentdev manages their *lifecycle* but
never their *history* — it runs no version-control commands. The lifecycle features all
work on ordinary directories:

- **Fork** — `agentdev profiles fork <src> <dst>` branches memory/config to try
  something risky, then keep or throw it away (a plain folder copy).
- **Archive / move** — `tar` or copy a profile to move it between machines; transcripts
  and runtime state travel with it.
- **Discard / gc** — clean rooms are removed on exit; `gc` sweeps crash leftovers.

**Versioning is deliberately out of scope — and left to you.** If you want snapshots,
roll-back, diffs, or a remote, put the folder under git (or anything else) yourself; it is
just a directory. agentdev's one concession is a seeded `.gitignore` so that, should you do
so, credentials are never committed. We may revisit a lighter built-in provenance log later,
but it will not be git, and it will not be mandatory.

**Reproducibility means pinning the environment, not just the config.** Claude Code's
on-disk fields are version-skewed — a profile written by one CLI build may
not replay on another. So `agentdev.lock` records the **image digest, Claude Code
version, template hash, and mount set**; `agentdev.meta.json` makes each profile
self-describing. Replay and "reproduce my bug" are honest only with this — and need no VCS.

Lifecycle and management surface:

```bash
agentdev profiles ls|new|rm|show|fork|gc            # manage named profiles (plain folders)
agentdev memory   ls|new|rm                         # manage memory stores (plain folders)
agentdev report [<profile>]                          # tokens, cache efficiency, cost, tools, egress
agentdev doctor                                      # check API key, podman, image, template
agentdev --dry-run                                   # print the exact mount + seed plan, don't launch
```

- **Clean-mode profiles** live under `clean_root` (optionally **tmpfs**, so nothing ever
  hits disk), are named by run id, and are removed on clean exit; `gc` sweeps crash
  leftovers; `--keep` promotes one and prints its path.
- **Named profiles and memory stores** persist until explicitly removed.
- **Cost is free to attribute** because each clean run is exactly one profile:
  `report` reads the transcript's token/cache accounting (cache reads dominate real
  cost) and summarizes per run; `--budget` can abort a runaway.
- **Fleet / best-of-N** (later): `--clean --fan-out N` runs N isolated clean rooms over
  one prompt/repo so you can compare the resulting patches — a natural superpower of
  reproducible, isolated runs.

---

## 12. Configuration

JSON — one grouped `agentdev-config.json` per working context. It answers the prompt's
questions directly: **what to mount read-only / read-write**, **where the config template
comes from**, **where runtime (profile/memory) folders are created and mounted**, and **which
folder the agent's shell starts in**.

### Resolution order (first found wins per key; CLI always wins)

1. **CLI flags** — `--clean`, `--remember`, `--profile`, `--template`, `--net`, `--workdir`,
   `--patch-only`/`--cow-workspace`, `-ro`/`-rw` paths.
2. **Per-project config** — `./agentdev-config.json` in the launch directory (or `-c <path>`).
3. **User config** — `~/.agentdev/config.json`.
4. **Built-in defaults.**

External mounts (the configs' `mounts.read_only`/`mounts.read_write` maps, `-ro`/`-rw` args,
env var) combine as a **union** via agentdev's own mount collector, with a `"source":
"destination"` / `&`-mirror grammar and collision checks. The **profile**, **memory store**,
and **template** each resolve to exactly one authoritative value — one agent home per run.

### Example

```json
{
  "agent": {
    "name":  "claude",
    "image": "ghcr.io/gherlein/agentdev@sha256:…"
  },
  "profile": {
    "default_mode":  "clean",
    "profiles_root": "~/.agentdev/profiles",
    "clean_root":    "~/.cache/agentdev/clean",
    "memory_root":   "~/.agentdev/memory"
  },
  "template": {
    "source":   "~/.agentdev/templates/default",
    "layers":   ["base-claude", "python-project"],
    "strategy": "copy",
    "include":  ["CLAUDE.md", "settings.json", "hooks", "skills", ".mcp.json"]
  },
  "auth": {
    "mode": "auto"
  },
  "workspace": {
    "isolation": "mount",
    "trust":     "skip-permissions",
    "workdir":   "."
  },
  "network": {
    "mode":  "isolated",
    "allow": ["api.anthropic.com", "registry.npmjs.org", "proxy.golang.org"]
  },
  "mounts": {
    "read_only":  { "~/ref/standards": "/external/standards", "../sibling-repo": "&" },
    "read_write": { "~/out/shared": "/external/shared" }
  }
}
```

A repo can ship a committed `agentdev-config.json` pinning the template, default mode, and a
stable mount set so `agentdev` starts the same for everyone there, while host-specific
absolute paths stay in the user config. Same portability rule as localdev: relative
paths and `&` are safe to commit; absolute host paths are not. **Any error in the
authoritative config/template aborts before the container starts** (fail-closed).

---

## 13. Patterns adopted (built fresh, not inherited)

`agentdev` is a **new, self-contained** tool. It owns its own container image, entrypoint,
mount library, and launcher, and depends on localdev for nothing at build or run time.
What it *adopts* — as proven patterns it re-implements — are: a hardened image with a
non-root `developer` user and `--userns=keep-id` ownership remapping, an external-mount
union (CLI + env + file, with collision detection and `&`), SSH agent forwarding, host TLS
trust-anchor passthrough, optional USB passthrough, a host-network variant, the
remote-podman story, and the entrypoint's **host-home symlink** (which lets an absolute
`$HOME` resolve inside the container — the mechanism that makes mounting a profile at the
host home path work). Every one of these lives in agentdev's own code.

The **core choice**: where localdev mounts `$HOME/.claude → ~/.claude (rw)` and
`$HOME/.claude.json` (the agent "is you"), agentdev mounts `<profile>/.claude` and
`<profile>/.claude.json`
and **never** touches the host's real ones; and it adds the optional workspace (§9) and
network (§10) isolation tiers on top.

---

## 14. Requirements summary

### Functional
- F1. Launch a container with the current directory as the read-write workspace.
- F2. Mount a **profile** as the agent's home (`~/.claude` + `~/.claude.json`), never the
  host's real agent state.
- F3. **Clean mode:** fresh throwaway profile seeded only from the template; discarded on
  exit (keep with `--keep`).
- F4. **Remember mode:** a clean-room home with a **persistent memory layer** mounted at
  the deterministic memory path; fresh transcripts, durable memory.
- F5. **Named mode:** create-on-first-use and thereafter reuse a persistent profile.
- F6. Read a config file declaring read-only mounts, read-write mounts, the template
  source, and the profile/memory roots where runtime folders are created and mounted.
- F7. Seed authored config from a template (`copy`; later `overlay-ro`; composable
  layers), with template linting; `--reseed` to re-apply config only.
- F8. Forward `ANTHROPIC_API_KEY` for clean/remember; support opt-in per-profile
  credential inheritance and interactive login for named profiles.
- F9. **Plain-folder** profiles and memory stores (`fork`, archive, `gc`); no built-in
  version control — a seeded `.gitignore` is the only concession, so user-run git stays
  secret-safe.
- F10. **Workspace isolation** options: `mount` (default), `cow`, `patch-only`.
- F11. **Network isolation** options: `isolated` (default), `host`, `allowlist` with
  egress logging.
- F12. Management + introspection: `profiles`, `memory`, `report`, `doctor`, `--dry-run`.
- F13. Provide (in agentdev's own image and launcher) an external-mount union, SSH
  forwarding, TLS passthrough, and UID/GID ownership mapping.

### Non-functional
- N1. **Isolation:** a clean run is provably free of prior history/memory/credentials and
  cannot mutate the host's real `~/.claude`; `allowlist` + `patch-only` make a run safe
  even for untrusted prompts.
- N2. **Reproducibility:** same template + pinned image/CLI + same inputs ⇒ same starting
  state; `agentdev.lock` + `agentdev.meta.json` make profiles self-describing.
- N3. **Portability:** a profile/memory store is a plain folder that can be archived and
  moved as-is; if you put it under git yourself, the seeded `.gitignore` keeps secrets out
  of any remote.
- N4. **Parallel-safe:** concurrent runs use distinct profiles with no shared mutable
  state; a named profile in use is locked against a second concurrent launch.
- N5. **Fail-closed config:** any error in the authoritative config/template aborts before
  the container starts.
- N6. **Secret-safe:** nothing secret is written into a folder that could be retained or
  pushed; a credentialed profile is clearly marked and never synced to a shared remote.

### Non-goals (for now)
- Not a replacement for localdev's "I am me" workflow.
- Not multi-agent on day one (Claude Code first; §16).
- Not a secrets manager; it forwards an env key and optionally lets a named profile hold
  its own login, nothing fancier.
- Not cloud orchestration, though the same remote-podman approach applies directly.

---

## 15. Open questions

1. **How much of `.claude.json` to seed** for a believable-but-clean home — fresh
   identity, empty `projects` map, which feature-flag caches to omit so a clean run does
   not re-fetch everything every time.
2. **Copy vs. overlay default** — ship `copy` now; make `overlay-ro` the eventual default
   for hard config immutability, or leave it opt-in?
3. **Plugin/skill cache** — `plugins/` and synced `skills/` are large regenerable caches.
   Seed empty (truly clean, slower first run) or share a read-only host cache (faster,
   slightly less pristine)? Likely a `warm_cache` toggle.
4. **Memory-store granularity** — one global store per name, or per-repo sub-stores keyed
   by workspace? How to merge when the same store is used from two repos at once.
5. **allowlist mechanics** — filtering proxy vs. network-namespace firewall under rootless
   podman; how to inject the proxy's CA without weakening the clean-room guarantee.
6. **cow/patch-only implementation** — overlayfs vs. `git worktree` clone vs. rsync-back;
   how to present the resulting diff for review.
7. **Image build & Claude Code pinning** (now that agentdev ships its own image) — bake a
   known-good CLI version into the image, or install at build from a pinned npm tag; how
   `agentdev doctor`/`build` keep the image digest and CLI version in the lock honest.
   *(Resolved separately: agentdev is its own repo with its own image, entrypoint, and
   mount library — it does not depend on localdev.)*

---

## 16. Roadmap: Claude first, then the rest

The profile abstraction generalizes cleanly because every coding agent we care about keeps
state in a well-known home dir (`~/.claude`, `~/.opencode`, `~/.pi`, `~/.omp`, `~/.kit`).
A profile is simply "the home dir(s) for *this* agent."

- **Phase 1 — Claude only, core.** Profile = `.claude/` + `.claude.json`; clean, remember,
  and named modes; plain-folder profiles & memory stores (no built-in version control);
  template seeding (`copy`) with linting; API-key auth; `profiles` / `memory` / `doctor` /
  `--dry-run`; and agentdev's own image, entrypoint, and mount library. Ship this and prove
  the clean-room guarantees.
- **Phase 2 — safety & insight.** `--net=allowlist` + egress logging; `--cow-workspace` /
  `--patch-only`; tmpfs clean rooms; `report` (cost/cache/tools/egress) + `--budget`;
  concurrency lock; `overlay-ro` templates; credential-holding named profiles.
- **Phase 3 — scale & multi-agent.** Fleet / best-of-N (`--fan-out`); composable template
  layers and `fork` workflows; generalize `[agent]` so one config drives claude,
  opencode, pi, each with isolated clean/named profiles and a shared, agent-agnostic
  memory store. The CLI gains `--agent <name>`; mounting is identical — only the home
  paths and the authored-config `include` list differ.

The north star stays fixed: **the agent's entire self — what it was told, everything it
remembers, and everything it did — is one folder you control (version it when and where
you choose), that you can wipe for a clean room, hand back to pick up where it left off,
or let it remember what it learned while forgetting the chatter.**
