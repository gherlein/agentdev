# agentdev — Vision

> An isolated, containerized environment for running coding agents where **all of the
> agent's "self"** — its authored config, its generated history, and its learned memory —
> lives in a single, swappable folder on the host, and where **one config file defines the
> entire launch**. Run it as a **clean room** (a brand-new user with no past), as a
> **remembering agent with clean history** (keeps what it learned, forgets the chatter), or
> against a **named profile** that carries everything forward — and lock the network down so
> a run in dangerous mode is safe.
>
> **agentdev is agent-agnostic by design.** The abstraction — a profile is "the home
> dir(s) for *this* agent" — generalizes across every agent whose state lives in a
> well-known home. **It supports Claude Code today; other agents are the next thing we
> add** (§14). The name reflects where this is going, not a limitation of where it starts.

**The design goal, in one line:** reading the config file tells you exactly what the
container gets — the agent, the model, an optional one-shot prompt, every mounted folder
and whether it is read-only, and how much of the internet is reachable. Nothing important
comes from outside the file, and nothing in the file is silently ignored.

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
- **A single source of truth.** One config file declares the whole run, so launching the
  same task twice — or handing it to a teammate — starts identically.
- **Safety end to end.** When I run in dangerous mode, isolate the agent's home and lock
  down the network it can reach.

`agentdev` is **built fresh and stands alone** — it ships its own container image, its own
entrypoint, and its own mount logic, with no dependency on localdev's code, image, or
launchers. It adopts the hardening localdev proved out — a hardened image, a non-root
user, `--userns=keep-id` ownership mapping, external mounts, TLS trust passthrough, SSH
agent forwarding — and **implements all of it itself**, while changing **one thing at the
core**: the agent's home is no longer your host `~/.claude`. It is a **profile folder**
that `agentdev` creates fresh, re-uses by name, or layers memory into.

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
| **Secrets** | Auth material | `.credentials.json`, `policy-limits.json` | **Never copied into a clean room**; auth comes from a forwarded API key (§7) |

(This taxonomy follows a file-by-file audit of which files Claude Code authors, which it
generates, and which are sensitive, verified against Claude Code CLI 2.1.300. Memory lives per-project under
`projects/<encoded-dir>/memory/`; because the workspace path is fixed for a given
launch, that encoded path is deterministic — so agentdev can mount a persistent memory
directory *into* an otherwise-clean profile at exactly the right place.)

### The profile

A **profile** is a single host directory that holds a complete, self-contained agent
home. It is a **plain folder** — agentdev never versions it (§9). If you want history,
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
│   │   └── memory/             ← MEMORY LAYER — independently mountable (§6)
│   ├── history.jsonl           ┐
│   ├── file-history/ sessions/ │  history layer — generated runtime state
│   └── jobs/ state/ ...        ┘
├── .claude.json                → mounted to ~/.claude.json (identity, per-project map)
├── agentdev.meta.json         → template used, created-at, mode, agent
└── agentdev.lock              → pinned image digest + CLI version + template hash (§9)
```

Mounting this profile — instead of the host's real `~/.claude` — is the whole trick.
The agent gets a complete, believable home that is *this folder and nothing else*, so
its entire life story is captured in one place we can seed, fork, reuse, or delete — and
that you are free to version yourself, outside the tool, if you want history.

---

## 3. Three modes over one abstraction

All three modes are the same mount with different answers to *where the profile lives,
whether it survives, and which layers are fresh*. The mode is set by `profile.mode` in
the config file:

| Mode | `profile.mode` | Memory | History | Profile lifetime |
|---|---|---|---|---|
| **Clean room** | `clean` | **fresh** | **fresh** | throwaway (kept with `profile.keep`) |
| **Remember, clean history** | `remember` (+ `profile.memory_store`) | **persistent** (mounted) | **fresh** | throwaway home + persistent memory store |
| **Named / persistent** | `profile` (+ `profile.name`) | persistent | persistent | kept under `profiles_root` |

- **Clean room** — a genuine brand-new user: no prior transcripts, no memory, a fresh
  `.claude.json`, API-key auth with no credential file, discarded on exit. The strict
  guarantees are spelled out in §4.
- **Remember, clean history** — the everyday sweet spot. A clean-room home (fresh
  transcripts, fresh identity) with a **persistent memory layer** mounted in (§6). The
  agent keeps what it learned across runs but never carries stale conversation context
  or compaction debris, which also keeps cost down.
- **Named / persistent** — resolve (or first-time create and seed) a profile under
  `profiles_root`; thereafter reuse it as-is so everything accumulates. The classic
  "isolated but fully re-usable" case.

The only real differences between modes are *where* the profile lives, *whether* it
survives the run, and *which layers are fresh vs. mounted*. Seeding, mounting, and the
container are identical.

---

## 4. Clean mode, precisely

A clean-room run guarantees:

1. **No prior conversation** — no `projects/*/*.jsonl` from any other run.
2. **No prior memory** — no `projects/*/memory/` carried in (unless a memory store is
   configured, which is then the only persistent thing — see §6).
3. **No prior prompt log** — a fresh, empty `history.jsonl`.
4. **No inherited identity or trust** — a fresh `.claude.json`: new identity, empty
   per-project trust/metrics map, no `hasTrustDialogAccepted` from past runs (§7).
5. **No persistent credentials on disk** — auth is a forwarded `ANTHROPIC_API_KEY`; no
   `.credentials.json` is copied in, and none the run writes survives (the profile is
   discarded; with tmpfs it never hits disk — §9).
6. **Only the authored template as a starting point.**
7. **Discarded on exit** — overridable with `profile.keep`, which prints the retained path.

The mental test: *a clean-room run is indistinguishable from a brand-new user who just
installed Claude Code, dropped in the standard config, and ran one task.* Two clean runs
of the same prompt against the same repo differ only by model nondeterminism, never by
leftover state.

A clean room still gets everything that is about *isolation, not deprivation*: the
workspace, declared external mounts, network, SSH agent forwarding, and host TLS trust.

---

## 5. Seeding: how the template becomes a profile

One strategy: **copy.** At profile creation, agentdev copies the template's `include`
list into `<profile>/.claude/`, creates empty runtime scaffolding (`projects/`,
`history.jsonl`, a minimal valid `.claude.json`), and lets everything be writable
thereafter. The profile is a real, self-contained home you can `tar`, move, or (if you
put it under git yourself) push to a remote. There is no overlay/immutable-template
mechanism: if you want an immutable authored baseline, keep the template under git and
re-copy from it — ordinary file management, no special machinery.

Named profiles are seeded **once** on first creation and never silently re-seeded, so
your drift survives. Seeding **lints** the template (hooks executable, `settings.json`
schema-valid, skills well-formed) and fails closed, matching localdev's philosophy.

---

## 6. The memory layer: clean history, persistent memory

This is the mechanism behind the middle mode in §3, and the sharpest expression of the
project's goal of isolating *memory* specifically.

Because memory lives at a **deterministic path** — `projects/<encoded-workspace>/memory/`
for the launch directory — agentdev can:

1. build an otherwise-clean profile (fresh config, fresh transcripts, fresh identity),
   and
2. bind-mount a **persistent memory store** into the memory path, leaving the rest of
   the profile ephemeral.

The result: the agent writes and reads real, durable memory, but every session's
transcript starts empty. Properties worth calling out:

- **A memory store is its own named, portable folder** (`memory_root/<name>`),
  independent of any one profile — so memory can be shared across repos and across
  modes. It is a plain folder; agentdev does not version it.
- **History is yours to keep.** If you want "what did the agent learn, and can I undo
  that?", put the store under git yourself — then ordinary `git diff` / `git log` /
  `git revert` answer it. agentdev deliberately wraps none of this.
- **Clean rooms stay clean.** `profile.mode: clean` with no store configured mounts *no*
  memory layer; `profile.mode: remember` with a store is precisely "amnesiac about
  conversations, but keeps what it learned."

---

## 7. Authentication and trust in an isolated home

Auth is set by `auth.mode` in the config file:

- **`auto` (default) → detect what the host uses and do that.** At launch agentdev
  resolves: an `ANTHROPIC_API_KEY` in the environment → API-key env; else a **named
  profile** with a readable host subscription login → inherit it; else interactive login.
  So a named-profile launch "just works" with whatever you already use on this machine.
- **API key env (`api-key-env`).** Forward `ANTHROPIC_API_KEY` into the container and seed
  **no** `.credentials.json`. Nothing secret is written to a folder that might be kept.
- **Inherit credentials (`inherit-credentials`), named profiles only.** Copy the host's
  subscription `~/.claude/.credentials.json` into the profile once (mode `600`, gitignored)
  so a Claude Pro/Max login carries in without an env var. The secret now lives in that
  folder — treat the whole profile as sensitive (`chmod 700`); never push it to a shared
  remote. Refused for clean/remember: a secret is never copied into a throwaway home.
- **Interactive (`interactive`).** Forward nothing; log in inside the container. Lasting
  for a named profile, ephemeral for clean/remember.

A non-Anthropic model provider (§8) authenticates with its own credentials, forwarded by
name through `model.pass_env`.

**Trust-dialog friction.** A fresh `.claude.json` leaves per-project
`hasTrustDialogAccepted` unset, so a clean room would prompt to trust the workspace.
`workspace.trust` controls this: `skip-permissions` (intended for running
`--dangerously-skip-permissions`), `workspace-only` (pre-seed trust for exactly the
workspace path and nothing else — the clean-room-minimal choice), or `prompt` (leave the
normal dialog in place).

---

## 8. Network & egress isolation

The container's network reach is set by `network.mode`:

- **`off` (default)** — ordinary networking; the container can reach the whole internet.
- **`none`** — no network at all.
- **`allowlist`** — only an allowlist of destinations is reachable, via a filtering proxy
  sidecar on an internal (no-egress) network; everything else is refused. This closes the
  exfiltration path that "isolated filesystem, open network" leaves open. Domain-level by
  default; an opt-in MITM tier (`network.mitm`) filters per-URL. Egress is recorded when
  `network.log` is set, giving an auditable answer to "where did this agent talk to?"

Under `allowlist`, the model endpoint (§10) must itself be on the allowlist, or the agent
cannot reach its model — agentdev checks this before the container starts.

For an untrusted task, combine `network.mode: allowlist` with a **read-only workspace**
(`mounts.workspace: "ro"`) and no SSH (`sandbox.ssh: false`). The
[`examples/isolated`](./examples/isolated) config bundles exactly that.

---

## 9. Folder lifecycle and reproducibility

Profiles and memory stores are **plain folders and files.** agentdev creates and seeds
them, but it provides **no management subcommands and runs no version control** — you
manage them with ordinary tools:

- **Fork** — `cp -a <profile> <copy>` to branch config/memory and try something risky.
- **Archive / move** — `tar` or copy a profile between machines; transcripts and runtime
  state travel with it.
- **Delete** — `rm -rf <profile>`.
- **Version** — put the folder under git (or anything else) yourself.

Clean-mode profiles live under `clean_root` (optionally **tmpfs**, so nothing ever hits
disk), are named by run id, and are removed on clean exit; `profile.keep` retains one and
prints its path. Named profiles and memory stores persist until you remove them. The one
git-aware courtesy is a seeded `.gitignore` so that, *if* you version a profile yourself,
credentials are never committed.

**Reproducibility means pinning the environment, not just the config.** Claude Code's
on-disk fields are version-skewed — a profile written by one CLI build may not replay on
another. So `agentdev.lock` records the **image digest, Claude Code version, template
hash, and mount set**; `agentdev.meta.json` makes each profile self-describing. Replay and
"reproduce my bug" are honest only with this — and need no version control.

---

## 10. Configuration: one file defines the launch

Everything is one JSON file. **Reading it tells you the whole run.**

### Where the file comes from

1. **`-c` / `--config <path>`** on the command line.
2. else **`$AGENTDEV_CONFIG`** from the environment.
3. else **`./agentdev-config.json`** in the current directory.

If none exists, agentdev refuses to launch. There is **no user-config layer** and **no
environment-variable mount input**: a key the file omits takes its built-in default, and
nothing else. Relative paths in the file (mount sources, `template.source`,
`workspace.source`, `prompt.file`) resolve against the **directory that holds the file**,
so the file means the same thing wherever you run it from.

### The command line is tiny

The launcher's only options are:

- **`--dry-run`** — print the settled plan and the exact `podman` command; launch nothing.
- **`-c` / `--config <path>`** — select the config file (above).
- **`--prompt <file>`** — run the agent once, headless, on the prompt in `<file>` (overrides
  `prompt.file`), then exit. Cannot combine with `-- COMMAND`.
- **`-- COMMAND…`** — run COMMAND in the container instead of the interactive shell.

There are no other flags, and no subcommands. The agent, model, one-shot prompt, mounts,
network, auth, trust, and workspace all live in the file. The image is built out of band
(`make build`).

### Strict, fail-closed

The file is validated against a schema before any key is read. An **unknown or misspelled
key, a wrong type, or a value outside its allowed set aborts the launch** and names the
offending key. A security setting can never be silently disabled by a typo. Keys starting
with `//` are treated as comments.

### Example

```json
{
  "agent": {
    "name":  "claude",
    "image": "ghcr.io/gherlein/agentdev@sha256:…"
  },
  "model": {
    "id":       "claude-opus-5-5",
    "provider": "anthropic"
  },
  "profile": {
    "mode":          "clean",
    "profiles_root": "~/.agentdev/profiles",
    "clean_root":    "~/.cache/agentdev/clean",
    "memory_root":   "~/.agentdev/memory"
  },
  "template": {
    "source":  "~/.agentdev/templates/default",
    "include": ["CLAUDE.md", "settings.json", "hooks", "skills", ".mcp.json"]
  },
  "auth": {
    "mode": "auto"
  },
  "workspace": {
    "source":  ".",
    "trust":   "skip-permissions",
    "workdir": "."
  },
  "network": {
    "mode":  "allowlist",
    "allow": ["api.anthropic.com", "registry.npmjs.org", "proxy.golang.org"]
  },
  "mounts": {
    "workspace":  "rw",
    "read_only":  { "~/ref/standards": "/external/standards" },
    "read_write": { "~/out/shared": "/external/shared" }
  },
  "sandbox": {
    "ssh": true, "usb": true, "host_ca": true
  }
}
```

For an unattended one-shot run, add a `"prompt": { "file": "task.md" }` block: agentdev
mounts the file read-only and runs the agent headless on it, then exits. `workspace.source`
is the host folder mounted as the workspace (default: the config file's directory);
`model.base_url` and `model.pass_env` point Claude Code at a gateway or at Bedrock/Vertex.
A repo can commit its `agentdev-config.json` so everyone there launches the same way; keep
the sources portable (relative paths) if the committed file must work on other machines.

---

## 11. Patterns adopted (built fresh, not inherited)

`agentdev` is a **new, self-contained** tool. It owns its own container image, entrypoint,
mount library, and launcher, and depends on localdev for nothing at build or run time.
What it *adopts* — as proven patterns it re-implements — are: a hardened image with a
non-root `developer` user and `--userns=keep-id` ownership remapping, the configured
external mounts (with collision detection and the `&`-mirror grammar), SSH agent
forwarding, host TLS trust-anchor passthrough, optional USB passthrough, and the
entrypoint's **host-home symlink** (which lets an absolute `$HOME` resolve inside the
container — the mechanism that makes mounting a profile at the host home path work). Every
one of these lives in agentdev's own code.

The **core choice**: where localdev mounts `$HOME/.claude → ~/.claude (rw)` and
`$HOME/.claude.json` (the agent "is you"), agentdev mounts `<profile>/.claude` and
`<profile>/.claude.json` and **never** touches the host's real ones; and it adds the
optional network isolation tier (§8) on top.

---

## 12. Requirements summary

### Functional
- F1. Launch a container with a workspace folder (`workspace.source`, default the config
  file's directory) mounted at `/<basename>`, read-write or read-only.
- F2. Mount a **profile** as the agent's home (`~/.claude` + `~/.claude.json`), never the
  host's real agent state.
- F3. **Clean mode:** fresh throwaway profile seeded only from the template; discarded on
  exit (retain with `profile.keep`).
- F4. **Remember mode:** a clean-room home with a **persistent memory layer** mounted at
  the deterministic memory path; fresh transcripts, durable memory.
- F5. **Named mode:** create-on-first-use and thereafter reuse a persistent profile.
- F6. **One JSON config file declares the whole launch** — agent, model, optional one-shot
  prompt, read-only/read-write mounts and devices, network reach, template source, the
  profile/memory roots, auth, trust, workspace, and host passthroughs — and is validated
  **fail-closed** (unknown keys and invalid values abort before the container starts).
- F7. **Select the model:** `model.id`, `model.provider` (`anthropic`/`bedrock`/`vertex`),
  `model.base_url`, and provider credentials forwarded by name via `model.pass_env`. Under
  an allowlist the derived endpoint host must be allowed.
- F8. Seed authored config from a template (`copy`) with template linting.
- F9. **Auth:** `auto` detection; `api-key-env`; per-profile credential inheritance and
  interactive login for named profiles.
- F10. **Plain-folder** profiles and memory stores managed with ordinary tools; no built-in
  version control and no management subcommands — a seeded `.gitignore` is the only
  concession, so user-run git stays secret-safe.
- F11. **Network:** `off` (default) | `none` | `allowlist` with egress logging and an
  optional per-URL MITM tier.
- F12. **Minimal CLI:** launch from the config; `--dry-run` previews the settled plan and
  the `podman` command; `--prompt <file>` runs one headless prompt and `-- COMMAND` runs a
  command instead of the shell; `-c`/`$AGENTDEV_CONFIG`/`./agentdev-config.json` selects the
  file.
- F13. Provide (in agentdev's own image and launcher) the configured external mounts, SSH
  forwarding, TLS passthrough, USB passthrough, and UID/GID ownership mapping.

### Non-functional
- N1. **Isolation:** a clean run is provably free of prior history/memory/credentials and
  cannot mutate the host's real `~/.claude`; `allowlist` + a read-only workspace make a run
  safe even for untrusted prompts.
- N2. **Reproducibility:** same template + pinned image/CLI + same inputs ⇒ same starting
  state; `agentdev.lock` + `agentdev.meta.json` make profiles self-describing.
- N3. **Portability:** a profile/memory store is a plain folder that can be archived and
  moved as-is; if you put it under git yourself, the seeded `.gitignore` keeps secrets out
  of any remote.
- N4. **Parallel-safe:** concurrent runs use distinct profiles with no shared mutable
  state; a named profile in use is locked against a second concurrent launch.
- N5. **Fail-closed config:** the file is schema-validated; any unknown key, wrong type, or
  invalid value aborts before the container starts.
- N6. **Secret-safe:** nothing secret is written into a folder that could be retained or
  pushed; a credentialed profile is clearly marked and never synced to a shared remote.

### Non-goals (deliberately out of scope)
- Not a replacement for localdev's "I am me" workflow.
- **No CLI beyond `--dry-run`, `-c`/`--config`, `--prompt`, and `-- COMMAND`, and no
  profile/memory management subcommands** — profiles and memory stores are plain folders you
  manage yourself.
- **No workspace copy-on-write or patch-review tier, no overlay/immutable templates, no
  composable template layers, no fleet / best-of-N, no built-in cost accounting.** These
  were considered and cut; ordinary files, git, and a shell cover them.
- Not a secrets manager; it forwards an env key or named provider credentials, and
  optionally lets a named profile hold its own login, nothing fancier.
- Multi-agent beyond Claude Code is next (§14), not now.

---

## 13. Open questions

1. **How much of `.claude.json` to seed** for a believable-but-clean home — fresh
   identity, empty `projects` map, which feature-flag caches to omit so a clean run does
   not re-fetch everything every time.
2. **Plugin/skill cache** — `plugins/` and synced `skills/` are large regenerable caches.
   Seed empty (truly clean, slower first run) or share a read-only host cache (faster,
   slightly less pristine)? Likely a `warm_cache` toggle.
3. **Memory-store granularity** — one global store per name, or per-repo sub-stores keyed
   by workspace? How to merge when the same store is used from two repos at once.
4. **Image build & Claude Code pinning** — bake a known-good CLI version into the image, or
   install at build from a pinned npm tag; how the build keeps the image digest and CLI
   version in the lock honest.

---

## 14. Roadmap: Claude first, then the rest

The profile abstraction generalizes cleanly because every coding agent we care about keeps
state in a well-known home dir (`~/.claude`, `~/.opencode`, `~/.pi`, `~/.omp`, `~/.kit`).
A profile is simply "the home dir(s) for *this* agent."

- **Now — Claude only, core.** Profile = `.claude/` + `.claude.json`; clean, remember, and
  named modes; `copy` seeding with linting; model selection (id / provider / base_url /
  forwarded credentials); `auto` / api-key / inherit / interactive auth; network
  `off` / `none` / `allowlist` with egress logging; plain-folder profiles & memory stores;
  a single, strict, fail-closed config file; `agentdev.meta.json` + `agentdev.lock`; and
  `--dry-run`. Prove the clean-room guarantees.
- **Next — other agents.** Generalize `agent.name` so one config drives claude, then
  opencode / pi / omp — each with isolated clean/named profiles and a shared,
  agent-agnostic memory store. Only the home path(s), the memory-path convention, the
  headless prompt command, and the auth env differ; the mount plan, seeding skeleton, and
  folder lifecycle are identical.

The north star stays fixed: **the agent's entire self — what it was told, everything it
remembers, and everything it did — is one folder you control (version it when and where
you choose), that you can wipe for a clean room, hand back to pick up where it left off,
or let it remember what it learned while forgetting the chatter — and one config file
defines exactly how it runs.**
