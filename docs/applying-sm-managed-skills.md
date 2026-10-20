# Applying sm-managed skills to an agentdev profile

[`sm`](https://github.com/brightsign-playground/sm) (skills-mapper) manages a
single, agent-neutral **canonical store** of skills and places them into each
agent's own skills directory. agentdev runs an agent whose home is a **profile
folder**. This document shows how the two compose: how skills that `sm` manages
get applied to the agent running inside an agentdev container.

If you only remember one thing: **a profile's `.claude/skills/` is the interface.
Run `sm sync --copy --agent-home <profile>` to populate it, then launch agentdev
against that profile. The agent in the container reads the skills as if they were
its own.**

## Why this works — the shared seam

Two facts line up exactly:

1. agentdev already treats `skills/` as a first-class part of a profile. The
   default `template.include` is `CLAUDE.md`, `settings.json`, `hooks`,
   **`skills`**, `.mcp.json` (see `lib/config.sh`), and the profile's `.claude`
   is mounted into the container at `/home/developer/.claude`. So
   `<profile>/.claude/skills/<name>/` is a recognized, mounted location the agent
   reads from.
2. `sm`'s `--agent-home <dir>` flag re-roots the `claude-code` agent's skills
   directory (`~/.claude/skills`) into `<dir>/.claude/skills`. Point it at a
   profile and it writes to exactly the directory above.

The one requirement is **copy mode** (`sm sync --copy`). `sm`'s default fan-out
uses symlinks that point back at the host store — and a symlink target does not
exist inside the container, so it would dangle. `--copy` writes each skill as a
**real directory**, which survives being mounted into the sandbox. (Copy mode is
documented in `sm`'s README under "Overriding the store and the agent home".)

## The end-to-end

Prerequisites: `sm` installed; its `agents.toml` lists `claude-code` (run
`sm probe` or `sm init` once); and the canonical store is populated (that is a
producer's job — `git clone` a skills repo into it, a `.deb`, or a tool's
`install-skill` — never `sm`'s).

```sh
# 1. (one time) make sure sm knows about claude-code
sm probe --yes

# 2. apply the managed skills into the profile agentdev will mount
sm sync --copy --agent-home ~/.agentdev/profiles/research
#    → ~/.agentdev/profiles/research/.claude/skills/<name>/   (real dirs, each with a .sm-copy marker)

# 3. launch the agent against that profile; it reads the skills as its own
agentdev --profile research -- \
  claude --dangerously-skip-permissions -p "use the available skills to …"
```

Inspect or update at any time:

```sh
sm status --agent-home ~/.agentdev/profiles/research   # owned / unmanaged / dangling
sm sync   --copy --agent-home ~/.agentdev/profiles/research   # re-apply after the store changes
sm clean  --agent-home ~/.agentdev/profiles/research   # remove only the skills sm placed
```

## Two skill channels, coexisting

A profile can receive skills two ways, and they are designed to compose:

| Channel | For | Lands at | When |
|---|---|---|---|
| **agentdev template `skills/`** | Static skills baked into a profile's *identity* | `.claude/skills/` | at seed (`cp -a` of the template's `skills/`) |
| **`sm sync --copy`** | Dynamic, centrally-managed, refreshable skills from the store | `.claude/skills/` | whenever you provision |

They don't collide. Each `sm` copy carries a hidden `.sm-copy` provenance
marker; `sm` only ever refreshes or removes directories that have it, so a
template- or hand-placed skill (no marker) is reported as *unmanaged* and left
untouched. Conversely, agentdev's `--reseed` re-applies template items without
disturbing `sm`'s copies. Ownership is partitioned at the file level: `sm` owns
what it marked, the template owns the rest.

## Lifecycle: which mode to provision

- **Named / persistent profile (`--profile`): the clean fit.** Provision once;
  re-run `sm sync --copy --agent-home <profile>` whenever the store changes and
  `sm` reconciles and refreshes in place. Skills persist across runs with the
  rest of the profile.
- **Clean / remember (throwaway home):** the home lives at an agentdev-chosen
  per-run path that only exists during the run, so there is no stable directory
  to `sm`-provision beforehand. For a dynamic, managed skill set in these modes,
  either:
  - provision a **named profile** once and run `--profile` instead of `--clean`, or
  - bake a **static** set into the agentdev **template's** `skills/` directory so
    every seeded home gets it automatically.

## Where the steps must run

Both the store population and the `sm` copy happen **on the host, before
launch**. Do not run them inside the container: an agent that runs `sm` (or a
tool's `install-skill`) inside the sandbox writes to the container's own
`~/.local/share/skills` / `~/.claude/skills`, which is outside the mounted
profile — so the result is off the persisted path and vanishes when the
container exits. The profile is the hand-off artifact; the container is a pure
consumer.

## Fanning out across many runs

This composes with the one-shot orchestrator
([`examples/one-shot-orchestrator/`](../examples/one-shot-orchestrator/)): give
each worker a provisioned **named profile** (fork a base profile per worker and
`sm sync --copy` into each), then launch `agentdev --profile <worker>` for the
task. Each container then has the same managed skill set, materialized and
self-contained.

## Coupling

This integration is intentionally **loose** — the profile is the only contract,
and agentdev stays `sm`-agnostic (it still depends only on `podman` and
`python3`). You, or an orchestrator, run `sm` and then agentdev. A future
convenience could add an `agentdev --skills <store>` flag that shells out to
`sm sync --copy` as a pre-launch step, degrading gracefully when `sm` is absent;
until then, the two commands above are the integration.
