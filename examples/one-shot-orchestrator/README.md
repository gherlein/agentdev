# One-shot orchestrator

A minimal example of an external "master" process that spawns child processes,
each launching an **agentdev** container to do one task, and collects each
agent's result as a file.

## The model

```
master (orchestrate.sh)
  ├─ child 1: agentdev --clean -rw <ch>/w1 -- bash /external/w1/bin/worker.sh
  │             └─ podman run --rm (FOREGROUND) ── container ── claude -p "<task>"
  │                  ▲ bind mount ▼
  │             host: <ch>/w1/{in,out}  ⇆  container: /external/w1/{in,out}
  ├─ child 2: … <ch>/w2 …
  └─ waits on each child; its EXIT is the completion signal → read out/result.txt
```

Two signals, and one is free:

- **"I'm done"** — the child process exiting. `agentdev` runs `podman run --rm`
  in the **foreground**, so the launcher (our child) lives exactly as long as the
  container. `wait $pid` is the completion signal; no extra channel needed.
- **"Here is the data"** — a file. The agent writes `out/result.txt` with an
  atomic rename (temp file → `mv` in the same dir), so the master never reads a
  partial result. Data IPC is files; the directory is a per-run `-rw` mount.

Because each task runs in **clean mode**, every container gets its own throwaway
home, takes no profile lock, and runs fully concurrently — no single-instance
contention (see `DESIGN.md` §2.5). The channel dir is *our* host directory, not
the profile, so results survive the container's `--rm` teardown.

## Files

| File | Role |
|---|---|
| `orchestrate.sh` | The master: fan out tasks, throttle to `MAXJOBS`, collect results |
| `worker.sh` | Runs **inside** the container: read task, run `claude -p`, publish result atomically |
| `fake-agentdev` | A shim used only by the selftest — no podman/image needed |
| `selftest.sh` | Proves the plumbing end to end with the shim |
| `tasks.example` | Sample task list (one task per line) |

## Try it now (no image, no tokens)

```bash
./selftest.sh      # runs orchestrate.sh against fake-agentdev; expects SELFTEST: PASS
```

## Run it for real

Prerequisites: the agentdev image built (`agentdev build`), `agentdev` on `PATH`,
and an API key exported (headless `claude -p` can't do an interactive login):

```bash
export ANTHROPIC_API_KEY=sk-ant-...
./orchestrate.sh tasks.example
# or pass tasks directly:
./orchestrate.sh "Summarize README.md in 3 bullets" "List the lib/ files and what each does"
```

Results land in `<channel-root>/w<N>/out/result.txt` (the channel root is printed
at startup). `agentdev.log` and `stderr.log` sit beside each result for failures.

> **Autonomous (file-editing) tasks need a permission grant.** The sample tasks
> only *read*, so `worker.sh` calls plain `claude -p`. For a task like "implement
> the code" that edits files, add `--dangerously-skip-permissions` (or
> `--permission-mode acceptEdits`) to the `claude` line in `worker.sh` — a headless
> run otherwise stalls on approval prompts. The image's `clauded` alias does not
> help here, because the command is exec'd directly rather than through an
> interactive shell. See the root [`README.md`](../../README.md) → "Run a one-shot
> command (autonomous agent)".

### Knobs (environment variables)

| Var | Default | Meaning |
|---|---|---|
| `MAXJOBS` | `4` | Max concurrent containers |
| `WORKSPACE` | fresh temp dir | Host dir mounted as the agent's workspace. Point it at a repo if the task needs code (note: it is mounted **read-write** and shared by all workers in a run — use a copy per worker if they must not collide) |
| `CHANNEL_ROOT` | fresh temp dir | Where per-run `in/`,`out/` channels live |
| `AGENTDEV_AUTH` | `api-key-env` | Passed to `agentdev --auth` |
| `AGENTDEV` | `agentdev` | The binary to invoke (the selftest overrides this) |

## Passing the task

The task text is written to `in/task.txt` and read by `worker.sh`, rather than
baked into the command line — robust for long or multi-line tasks, and it doubles
as a demonstration of the inbound (master → agent) file channel. You could instead
pass it as an argv element (`-- bash worker.sh "$task"`); agentdev forwards the
trailing `-- …` verbatim, so a single arg survives intact.

## Spawn siblings, not nested containers

The controller runs on the **host** and spawns workers as **sibling** containers.
Do **not** have a worker create another agentdev container *inside itself*:

- It is not supported by default — the image runs unprivileged with no
  `/dev/fuse`, so nested rootless podman typically fails, and neither the
  `agentdev` launcher nor its image is present inside a worker.
- Even forced to work, the nested container's profile and workspace live inside
  the outer container (ephemeral, lost on exit, a second overlay layer).
- Agents nesting agents have no central concurrency limit — a container
  fork-bomb.

If a worker needs more instances, it should **request them from the host master**
over the channel (write a request into `in/`/`out/`), and the master — which owns
concurrency and cleanup — launches the new siblings. Keep the topology flat.

## Extending this

- **Streaming progress, not just a final result.** Keep the one-shot structure but
  add a host-side `inotifywait -m -e moved_to <ch>/w*/out` so the master reacts to
  intermediate files *before* the child exits. The agent (or a small in-container
  "herald") writes `out/NNNN.json` as it goes.
- **An explicit push channel.** Add a FIFO at `<ch>/wN/ctl`; the master blocks
  reading it and the agent writes one line per event (keep each under 4 KB so the
  write is atomic). Use this when "a file appeared" isn't enough and you want a
  payload or status code.
- **A persistent agent instead of one-shot.** Run the agent under a loop that polls
  `in/` between turns, and turn `ctl` into a Unix-domain socket for a real duplex
  protocol. This is the point where a background process inside the container earns
  its keep — but it is a bigger design than this example.
- **Shared identity across workers.** If the tasks should build on one profile's
  memory/config, `agentdev profiles fork base wN` per worker (each fork is its own
  single-instance folder) instead of clean mode.
