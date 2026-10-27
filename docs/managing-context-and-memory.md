# Managing Claude Code Context and Memory

A practical guide to the two things that most shape how a Claude Code session
behaves over time:

- **Context** — what is loaded into the model's window *right now*, and what each
  piece costs. You manage this to keep sessions fast, cheap, and focused.
- **Memory** — what *persists across sessions*, and where it lives. You manage
  this to control what Claude knows at the start of every session.

They are related but distinct: memory is one of the things that *costs* context
(a `CLAUDE.md` is loaded every session), but context also includes many things
that never persist (tool schemas, the live conversation). This document covers
both, then connects them to how **agentdev** profiles embody these concepts.

> **If you only remember one thing:** the window is a budget. Facts that must
> always be known go in `CLAUDE.md` (small, always resident); procedures go in
> **skills** (loaded only when invoked); tools you rarely use should be kept out
> of the default load so tool search never pulls their schemas in. Measure with
> `/context`, and move cost off the hot path rather than paying it every turn.

---

## Part 1 — Context: what it is and what it costs

### 1.1 Measure first: `/context`

Run `/context` inside a session to see the real resident breakdown. Don't guess —
the numbers are frequently surprising, and they change as you connect servers,
install plugins, and accumulate skills.

A representative breakdown, measured on a live session with ~13 connected MCP
servers (157 MCP tools) and ~100 skills:

| Category | Resident cost | Note |
|---|---|---|
| MCP **tool schemas** | **0 tokens** until used | Deferred behind tool search |
| MCP **server instructions** | ~700 tokens total | Short per-server blurbs, always resident |
| Potential if *all* MCP tools loaded | ~97k tokens | Only realized when tool search pulls them in |
| Built-in tool schemas (Artifact, etc.) | ~16k resident + ~27k deferred | Fixed harness overhead |
| Skills (names + descriptions) | ~10k tokens | ~100 skills, always resident |
| `CLAUDE.md` files | ~2.7k tokens | The part you most directly control |

The key insight: the motivation to trim connected servers is **not** mainly about
resident tokens (schemas are deferred and cost ~0 until used). It is about:

1. stopping tool search from loading 90k+ of schemas you never wanted,
2. faster startup and fewer live server connections, and
3. less chance the model reaches for an irrelevant tool.

### 1.2 Tool search — the deferred-loading mechanism

Most tool schemas (MCP and some built-ins) are **deferred**: only the tool's name
is known until something triggers a search that pulls its full schema into
context. This is why a dozen connected servers can cost almost nothing at rest.

Two controls:

- `ENABLE_TOOL_SEARCH` — accepts `auto`, `auto:N`, `true`, `false`. Tunes whether
  and how aggressively tool search runs.
- `"alwaysLoad": true` on a server — forces that server's tools to always load
  (bypassing deferral). Use sparingly; it is the opposite of what you usually
  want.

### 1.3 Skills — progressive disclosure

A **skill** is a directory with a `SKILL.md` (frontmatter + body) plus optional
supporting files. Only the `name` + `description` are resident at startup; the
**body loads only when the skill is invoked**. This "progressive disclosure" is
the mechanism that lets you keep long procedures available without paying for them
every session.

Consequences for context budgeting:

- Put **long procedures** in skills, not in `CLAUDE.md`. A 300-line procedure in
  `CLAUDE.md` costs you every turn; the same procedure in a skill costs nothing
  until it's used.
- The `description` is the *only* text the model matches on to auto-invoke, so
  write it as a trigger ("Use when the user asks X"), not a summary.
- Supporting files (`reference.md`, scripts) load on demand or are executed
  without being read into context at all — push detail there.
- ~100 skills still cost ~10k resident (names + descriptions). If that grows
  unwieldy, prune skills you never use rather than letting the catalog sprawl.

### 1.4 Subagents — context isolation

A **subagent** runs a task in its *own* context window and returns only its final
result. Use it to keep verbose, high-output work — test runs, log parsing, broad
code search — out of your main conversation. Built-ins like `Explore` run on a
cheaper/faster model and skip `CLAUDE.md`/git-status to stay lean.

Caveat: a subagent is not free — each one costs its own context window and adds
latency. Use subagents to *protect* the main context, not reflexively.

### 1.5 MCP servers — the biggest controllable lever

MCP servers expose tools over the Model Context Protocol. There are **three kinds**,
and they are controlled differently — `--mcp-config` does *not* govern all of them:

| Kind | Examples | How to enable/disable |
|---|---|---|
| **CLI / self-hosted** (stdio or http) | a local `codebase-memory` server | `claude mcp` commands, `--mcp-config`, `.mcp.json`, scopes |
| **claude.ai connectors** | Atlassian, M365, Slack, Box, … | claude.ai connector settings, or `/mcp` toggle — **not** `--mcp-config` |
| **Plugin-provided** | a server shipped inside a plugin | comes with the plugin; `/mcp` toggle; cannot `claude mcp remove` |

#### Scopes — where you register a server decides who loads it

| Scope | Flag | Stored in | Loads in |
|---|---|---|---|
| local (default) | `--scope local` | `~/.claude.json` (per-project) | that project only, private |
| project | `--scope project` | `.mcp.json` at repo root | that project, shared via git |
| user | `--scope user` | `~/.claude.json` | **every** project |

Precedence when a name is defined in several places:
`local → project → user → plugin → claude.ai connector`. The winning source's
*whole* entry wins (fields are not merged).

> **The biggest single lever:** don't register heavy servers in **`user`** scope —
> that is exactly what makes them resident in every project.

#### Launch-time selection

- `--mcp-config <file|json>…` — **additive**: adds these servers *on top of*
  whatever user/project/local config already loads. Repeatable.
- `--strict-mcp-config` — load **only** the servers named by `--mcp-config`,
  ignoring all other CLI-registered configs. (Whether strict also suppresses
  claude.ai connectors and plugin servers is unverified — confirm with `/context`
  inside the session.)

#### The per-session `--mcp-config` + alias pattern

Keep each self-hosted server in its own JSON file outside any repo, then opt in
per session with a shell alias. Files go under e.g. `~/.config/claude/mcp/`, one
per server, same shape as `.mcp.json`:

```json
{
  "mcpServers": {
    "codebase-memory": { "command": "codebase-memory-mcp", "args": ["--serve"], "env": {} }
  }
}
```

`${VAR}` / `${VAR:-default}` expansion is supported, so keep secrets in the
environment, not in the file (and `chmod 600` the files regardless):

```json
{
  "mcpServers": {
    "github": {
      "type": "http",
      "url": "https://api.githubcopilot.com/mcp/",
      "headers": { "Authorization": "Bearer ${GITHUB_MCP_TOKEN}" }
    }
  }
}
```

Then define aliases that use `--strict-mcp-config` so each gives a predictable,
minimal set rather than stacking on top of whatever is already registered:

```bash
# Clean session: NO mcp servers at all
alias cc='claude --strict-mcp-config'
# Only the codebase-memory server (e.g. for KB / docs work)
alias cc-kb='claude --strict-mcp-config --mcp-config ~/.config/claude/mcp/codebase-memory.json'
# Opt in to several (multiple --mcp-config flags merge)
alias cc-dev='claude --strict-mcp-config \
  --mcp-config ~/.config/claude/mcp/codebase-memory.json \
  --mcp-config ~/.config/claude/mcp/github.json'
```

#### Settings keys for `.mcp.json` approval

In `~/.claude/settings.json`, `.claude/settings.local.json`, or managed settings:

- `enableAllProjectMcpServers` — approve every server in project `.mcp.json`
  without prompting.
- `enabledMcpjsonServers` — approve specific named servers.
- `disabledMcpjsonServers` — reject specific servers everywhere (shows as
  `✘ Rejected`).

Do **not** confuse these with `disabledMcpServers` / `enabledMcpServers`, which
the `/mcp` toggle writes per-project into `~/.claude.json` and which cover
user/plugin/built-in servers, not `.mcp.json` approval. (Exact value types are
inferred, not doc-confirmed — verify with `/config`.)

#### `/mcp` (interactive)

Authenticate / re-auth / clear auth; show each server's tool count and drill into
its tools; `reconnect` (`/mcp reconnect all`); and **disable/enable a server**. A
toggled-off server stays listed as disabled and keeps its config, recorded
per-project in `~/.claude.json`. This is the documented way to disable a server
without removing it. (Whether a restart is needed after toggling is not
documented — test it in your build.)

### 1.6 A migration recipe for a bloated setup

1. For self-hosted servers currently always-on: `claude mcp list` to see scope,
   then `claude mcp remove <name>` and move the definition into a per-server JSON
   file under `~/.config/claude/mcp/`.
2. For rarely-used **claude.ai connectors**: disconnect in claude.ai, or `/mcp`
   toggle off per project.
3. Launch with the alias matching the task (`cc-kb`, `cc-dev`, or bare `cc`).
4. Confirm the result with `/context` inside the session.

---

## Part 2 — Memory: what persists across sessions

"Memory" in Claude Code is several distinct layers. Two are **authored by you**
(`CLAUDE.md` and its relatives); one is **written by Claude itself** (auto
memory). They load at different times and cost context differently.

### 2.1 The `CLAUDE.md` family — authored, loaded every session

A `CLAUDE.md` is a plain markdown file read **in full at the start of every
session**. Because it is always resident, it is the layer you most directly pay
for — keep it small.

| File | Scope | Committed? |
|---|---|---|
| `~/.claude/CLAUDE.md` | You, all projects (global preferences: style, tooling) | personal |
| `<repo>/CLAUDE.md` | This project, whole team (stack, conventions, build commands) | yes, to git |
| `.claude/rules/*.md` | Path-scoped subset, to keep the root file small | yes |
| `CLAUDE.local.md` | You, this project | no |

Guidelines:

- **Keep it to ~100–150 lines.** It loads every time; every line is a recurring
  cost.
- Put **facts** here ("the build command is `make build`", "never touch generated
  files"), not procedures.
- Move **path-specific** rules into `.claude/rules/*.md` so the root file stays
  lean and rules only apply where relevant.
- Put anything that must be **enforced every time** in a **hook**, not
  `CLAUDE.md` — `CLAUDE.md` is advisory; a hook is run by the harness and is
  guaranteed.

### 2.2 Auto memory — written by Claude

Claude Code also maintains its own **auto memory**: notes it saves from your
corrections and confirmations, without being asked, under:

```
~/.claude/projects/<project>/memory/
   ├── MEMORY.md          # the index, loaded at startup
   └── <topic>.md         # detail files, loaded on demand
```

Key mechanics:

- Only the **first 200 lines / 25 KB** of `MEMORY.md` load at startup; the detail
  files load on demand. So `MEMORY.md` is itself a progressive-disclosure index —
  one line per memory, with the substance in linked detail files.
- Each memory is typically one fact in one file, with frontmatter describing its
  type (user preference, feedback, project state, external reference) and a
  one-line description used to decide relevance during recall.
- Because auto memory reflects *what was true when written*, treat a recalled
  memory as background, not gospel — verify file/function/flag references still
  exist before acting on them.

### 2.3 The decision rule — which layer gets what

| You want… | Put it in | Why |
|---|---|---|
| A fact Claude should **always** know | `CLAUDE.md` | Small, always resident |
| A multi-step **procedure** | a **Skill** | Loads only when invoked |
| A rule that must **never be skipped** | a **Hook** | Harness-enforced, not advisory |
| **Isolated / parallel** heavy work | a **Subagent** | Its own context window |
| A reusable **external tool** | an **MCP server** | Portable, deferred until used |

The through-line: **don't pay every turn for something you need only sometimes.**
Facts are cheap and belong resident; everything else should be loadable on demand.

### 2.4 Partition knowledge by *audience*, not by location

When memory/knowledge grows beyond a single repo, the organizing principle is to
split it by *who needs it*, not by *where the code happens to live*:

- **Local knowledge** — a component's own tables, helpers, runbook. It describes
  code in *one* place, so **co-locating** it there is right: it versions
  atomically with the code and travels on clone.
- **Boundary knowledge** — cross-component contracts, shared models, system
  topology. It belongs to no single place, and a change to it already spans
  multiple places — so atomicity was never available, and co-locating it is pure
  cost (fragmentation, replication, drift). Centralize it in one source of truth
  and reference it as a pinned dependency.

> Co-location buys atomicity. Boundary knowledge cannot be atomic. Therefore
> co-locating boundary knowledge is pure cost.

The same instinct applies to `CLAUDE.md`: project facts belong in the repo's
committed `CLAUDE.md`; your personal, machine-specific preferences belong in
`~/.claude/CLAUDE.md` and never travel with the project.

---

## Part 3 — How this maps to agentdev

agentdev's premise is that **the agent's home is host folders you mount** — bound as
`/home/developer/.claude` and `/home/developer/.claude.json`, never the host's real
`~/.claude`. Every context/memory lever above lives inside that mounted home, and the
`mounts` keys decide how much of it persists.

### 3.1 Where each layer lives in the mounted home

| Layer | In the home | Notes |
|---|---|---|
| Authored `CLAUDE.md` | `<agent_folder>/.claude/CLAUDE.md` | You provide it (copy from `templates/claude/`, mount it, or write it into a kept home) |
| Auto memory | `<agent_folder>/.claude/projects/<ENC>/memory/` | The same `MEMORY.md` + detail-file layout as §2.2 |
| MCP config | `<agent_folder>/.claude.json` | `local`-scope servers are per-project inside the home |
| Skills / plugins | `<agent_folder>/.claude/…` | Resident cost applies inside the container just as on the host |

`<ENC>` is agentdev's deterministic encoding of the workspace mount name (`"-" + name`
with `.` → `-`), matching Claude Code's own `projects/<dir>` naming so auto memory lands
where the CLI expects it.

### 3.2 What persists is a function of what you mount

| You mount | Auto memory / history | Context implication |
|---|---|---|
| **nothing** (no `agent_folder`) | none — throwaway home discarded on exit | Zero inherited memory; cheapest, most reproducible (the clean room) |
| **only `mounts.memory`** (fresh home otherwise) | **persistent memory** at `.claude/projects/<ENC>/memory`; history stays fresh | Keeps learned memory across runs while transcripts start clean |
| **`mounts.agent_folder`** (a kept folder) | persistent — config, history, and memory all live in the folder | A durable identity that accumulates over time |

The important connection: `mounts.memory` points at the auto-memory directory from §2.2.
So the agentdev memory folder and Claude Code's own auto memory are the same mechanism —
agentdev just makes it a named, swappable, host-side folder you keep, fork, or discard
independently of the (otherwise ephemeral) home.

### 3.3 Practical guidance

- **Keep a lean `CLAUDE.md` in your starter kit.** It loads every session, so keep
  `templates/claude/CLAUDE.md` to facts, not procedures.
- **Mount only `mounts.memory` when you want learned memory but clean history.** You get
  persistence where it matters without dragging a growing transcript along.
- **Control MCP cost at the home boundary.** Because `.claude.json` lives in the home, a
  heavy server registered there is resident for every run — the same "don't make it
  `user`-scope" lever from §1.5.
- **Measure inside the container.** The host's `/context` reasoning applies identically to
  the agent running in the mounted home; check it there when a run feels heavy.

---

## Sources

Official Claude Code documentation:
- Memory (CLAUDE.md) — https://code.claude.com/docs/en/memory
- MCP — https://code.claude.com/docs/en/mcp
- CLI reference — https://code.claude.com/docs/en/cli-reference
- Settings — https://code.claude.com/docs/en/settings
- Settings reference — https://code.claude.com/docs/en/settings-reference
- Skills — https://code.claude.com/docs/en/skills
- Subagents — https://code.claude.com/docs/en/sub-agents

Companion notes (`~/gch-notes/claude-notes/`):
- `managing-mcp-context.md` — the MCP context-cost control surface (Part 1.5–1.6)
- `claude-code-extensions.md` / `claude-code-extensions-howto.md` — the extension
  mechanisms (CLAUDE.md, skills, subagents, hooks, MCP) and the decision rules
- `organizing-claude-files.md` / `problem-with-ocf.md` — partitioning knowledge by
  audience (Part 2.4)

> Some settings-key value types above are inferred, not doc-confirmed, and some
> `--strict-mcp-config` behavior is unverified. Confirm anything load-bearing with
> `/context` and `/config` in your actual build.
