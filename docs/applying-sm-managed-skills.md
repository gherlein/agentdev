# Applying sm-managed skills to an agentdev home

[`sm`](https://github.com/gherlein/sm) (skills-mapper) manages a single, agent-neutral
**canonical store** of skills and places them into each agent's own skills directory.
agentdev runs an agent whose home is **host folders you mount** (`mounts.agent_folder`). This
document shows how the two compose: how skills that `sm` manages get applied to the agent
running inside an agentdev container.

If you only remember one thing: **the agent home's `.claude/skills/` is the interface. Run
`sm sync --copy --agent-home <agent_folder>` to populate it, then launch agentdev with
`mounts.agent_folder` pointed at that folder. The agent in the container reads the skills as
its own.**

## Why this works — the shared seam

Two facts line up exactly:

1. agentdev mounts `<agent_folder>/.claude` into the container at `/home/developer/.claude`
   (see `lib/mounts.sh` + `lib/agents.sh`). So `<agent_folder>/.claude/skills/<name>/` is a
   recognized, mounted location the agent reads from.
2. `sm`'s `--agent-home <dir>` flag re-roots the `claude-code` agent's skills directory
   (`~/.claude/skills`) into `<dir>/.claude/skills`. Point it at the agent home and it writes
   to exactly the directory above.

The one requirement is **copy mode** (`sm sync --copy`). `sm`'s default fan-out uses symlinks
back at the host store — and a symlink target does not exist inside the container, so it would
dangle. `--copy` writes each skill as a **real directory**, which survives being mounted in.

## The end-to-end

Prerequisites: `sm` installed; its `agents.toml` lists `claude-code` (run `sm probe` once);
and the canonical store is populated (a producer's job — `git clone` a skills repo into it, a
`.deb`, or a tool's `install-skill` — never `sm`'s).

```sh
# 1. (one time) make sure sm knows about claude-code
sm probe --yes

# 2. apply the managed skills into the agent home agentdev will mount
sm sync --copy --agent-home ~/.agentdev/homes/research
#    → ~/.agentdev/homes/research/.claude/skills/<name>/   (real dirs, each with a .sm-copy marker)

# 3. launch the agent against that home (mounts.agent_folder: ~/.agentdev/homes/research in
#    agentdev-config.json); it reads the skills as its own
echo "use the available skills to …" > task.md
agentdev --prompt task.md
```

Inspect or update at any time:

```sh
sm status --agent-home ~/.agentdev/homes/research   # owned / unmanaged / dangling
sm sync   --copy --agent-home ~/.agentdev/homes/research   # re-apply after the store changes
sm clean  --agent-home ~/.agentdev/homes/research   # remove only the skills sm placed
```

## Two skill channels, coexisting

An agent home can receive skills two ways, and they are designed to compose:

| Channel | For | Lands at | When |
|---|---|---|---|
| **starter kit `skills/`** | Static skills you hand-place into a home | `.claude/skills/` | when you set up the home (copy from `templates/claude/` or by hand) |
| **`sm sync --copy`** | Dynamic, centrally-managed, refreshable skills from the store | `.claude/skills/` | whenever you provision |

They don't collide. Each `sm` copy carries a hidden `.sm-copy` provenance marker; `sm` only
refreshes or removes directories that have it, so a hand-placed skill (no marker) is reported
as *unmanaged* and left untouched.

## Lifecycle: persistent vs ephemeral

- **Persistent home (`mounts.agent_folder` set): the clean fit.** Provision once; re-run
  `sm sync --copy --agent-home <agent_folder>` whenever the store changes and `sm` reconciles
  in place. Skills persist across runs with the rest of the home.
- **Ephemeral (no `agent_folder`):** the home only exists during the run, so there is no stable
  directory to `sm`-provision beforehand. For a managed skill set, use a **kept `agent_folder`**
  and provision it on the host before launch.

## Where the steps must run

Both the store population and the `sm` copy happen **on the host, before launch**. Do not run
them inside the container: an agent that runs `sm` inside the sandbox writes to the container's
own `~/.claude/skills`, which is off the persisted path and vanishes when the container exits.
The agent home is the hand-off artifact; the container is a pure consumer.

## Fanning out across many runs

This composes with the one-shot orchestrator
([`examples/one-shot-orchestrator/`](../examples/one-shot-orchestrator/)): give each worker its
own agent home (`cp -a` a base home per worker and `sm sync --copy` into each), then point each
worker's `mounts.agent_folder` at its fork. Each container then has the same managed skill set,
materialized and self-contained.

## Coupling

This integration is intentionally **loose** — the agent home is the only contract, and agentdev
stays `sm`-agnostic (it still depends only on `podman` and `python3`). You, or an orchestrator,
run `sm` and then agentdev.
