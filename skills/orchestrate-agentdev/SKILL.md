---
name: orchestrate-agentdev
description: >-
  Use when the user wants to run one or more tasks in isolated agentdev
  containers and collect the results — e.g. "fan these subtasks out to separate
  agents", "run each of these in its own sandbox", "spin up N agentdev workers
  for this", or driving a batch of unattended `claude -p` jobs. Covers launching
  one or many agentdev sessions, passing each a task, and getting results back.
  Not for a single interactive agentdev session the user runs themselves.
---

# Orchestrating agentdev sessions

Spawn one or more **agentdev** containers, hand each a task, and collect results.
Each worker is an isolated, fresh agent; the controller (you) fans out and
gathers. This skill is the procedure and the safety rules — the working
implementation lives in `examples/one-shot-orchestrator/` in the agentdev repo.

## Before doing anything: confirm and plan

Launching workers **spawns containers and spends tokens**. Always:

1. Confirm the exact task list and the max concurrency with the user.
2. Show the command(s) you will run, and offer `--dry-run` first (it prints the
   resolved `podman` command and changes nothing).
3. Only launch real workers after an explicit go-ahead. Never auto-spawn a fleet.

## The primitive — one worker, one task

Everything is in a config file (there are no launch flags but `-c`, `--dry-run`,
and `--prompt`). The cleanest unattended worker writes the task to a file and runs
it with `--prompt`, which handles stdin and skip-permissions for you:

```bash
cat > worker.json <<'EOF'
{ "profile": {"mode": "clean"}, "auth": {"mode": "api-key-env"},
  "workspace": {"source": "/path/to/repo"} }
EOF
echo "<the task>" > task.md
answer=$(agentdev -c worker.json --prompt task.md)
```

Three things are mandatory for an **unattended** worker (each fails silently or
hangs if omitted):

- `auth.mode: "api-key-env"` with `ANTHROPIC_API_KEY` set — headless runs cannot do
  an interactive login, and clean mode does not inherit a subscription. This also
  keeps account-level claude.ai connectors from leaking into the worker.
- Use `--prompt <file>` (or `prompt.file`) rather than a raw `-- claude -p "…"`: it
  runs `claude --dangerously-skip-permissions` with stdin closed, so the worker
  neither stalls on approvals nor hangs on a TTY. If you do use `-- claude` yourself,
  you must add those yourself.
- `workspace.source` is the repo the task is about (default: the config file's dir).

agentdev prints its diagnostics to **stderr**, so stdout is clean — capturing
`$(…)` gives you just the agent's answer.

## Getting results back

- **Simple:** capture stdout, as above. Good for one text answer per task.
- **Structured / multiple artifacts:** bind a per-run channel dir via the config's
  `mounts.read_write` map (`{ "<host-dir>": "/external/<run>" }`); the worker writes its
  result there with an **atomic rename** (temp → `mv`), and you read it after the
  worker exits. Completion needs no signal of its own: `agentdev` runs `podman
  run --rm` in the foreground, so the worker process exiting *is* "task done".
  `examples/one-shot-orchestrator/worker.sh` does exactly this.

## Fanning out (many workers)

- Prefer `examples/one-shot-orchestrator/orchestrate.sh <tasks-file>` — it already
  spawns one clean worker per task, throttles to `MAXJOBS`, waits on each child,
  and collects `out/result.txt`. Run its `./selftest.sh` to see the flow with no
  image or tokens.
- If issuing commands yourself: background each worker and `wait`, throttling to a
  sane concurrency (e.g. 4). Each `profile.mode: "clean"` worker takes **no profile
  lock**, so they run concurrently and safely.
- **Never point multiple workers at one named profile** — the single-instance guard
  refuses the second. For a shared identity/skills, fork the profile folder
  (`cp -a base wN`) per worker, or provision each worker profile with
  `sm sync --copy --agent-home <worker-profile>` (see
  `docs/applying-sm-managed-skills.md`). Do provisioning **host-side, before
  launch** — a worker cannot usefully provision itself from inside its sandbox.

## Do not nest — spawn siblings from the host

Always run the workers from the **host** (or wherever the controller runs), as
sibling containers side by side. **Never** have a worker create another agentdev
container *inside itself* (running `podman`/`agentdev` within its own sandbox):

- It is not supported by default — the image runs unprivileged with no
  `/dev/fuse`, so nested rootless podman typically fails, and the launcher and
  agentdev image aren't present inside a worker anyway.
- Even when forced to work, the nested container's profile and workspace live
  inside the outer container's filesystem — ephemeral, lost on exit, and stacked
  on a second overlay.
- Recursion (agents nesting agents) has no central concurrency limit — a
  container fork-bomb.

If a worker needs more agentdev instances, it must **ask the host controller** to
spawn them — e.g. write a request into its channel's `in/`/`out/` dir and let the
host master launch the new siblings (which it can throttle and clean up). The
worker never launches containers itself.

## Procedure checklist

1. Gather the task list; agree on concurrency.
2. Ensure `ANTHROPIC_API_KEY` is exported and the image is built (`make build`).
3. Dry-run one worker (`--dry-run`) and show it.
4. On go-ahead, launch — via `orchestrate.sh` for a batch, or the primitive for one.
5. Collect each result (captured stdout, or `<channel>/*/out/result.txt`).
6. Report per-task success/failure; a worker's non-zero exit or missing result
   file means it failed — surface its `stderr.log`/`agentdev.log`.

## References (in the agentdev repo)

- `examples/one-shot-orchestrator/` — the working controller + worker + selftest.
- `docs/user-guide.md` §12 — the one-shot prompt contract.
- `docs/applying-sm-managed-skills.md` — giving workers a managed skill set.
- `docs/managing-context-and-memory.md` — auth modes and the three kinds of MCP.
