# Example: a folder per working context

This folder is a self-contained agentdev working context. It holds everything that
defines the run:

```
profile-folder/
├── agentdev-config.json   # all settings (mode, auth, trust, mounts, …) + the entry folder
└── .envrc                 # per-context environment, loaded by direnv in the container
```

The idea: one folder per thing you work on. Its `agentdev-config.json` pins how the agent
runs, `workspace.workdir` makes the agent's shell start right here, and `.envrc` sets up the
environment — so `agentdev` launches straight into a ready-to-work shell.

## Run it

From inside this folder (it is the workspace, mounted at `/profile-folder`):

```bash
cd examples/profile-folder
agentdev                      # reads ./agentdev-config.json automatically
```

or point at the config explicitly from anywhere:

```bash
agentdev -c examples/profile-folder/agentdev-config.json
```

See the settled plan without launching:

```bash
agentdev --dry-run            # note the "entry folder:" line and -w / AGENTDEV_WORKDIR
```

## What the config does

- **`profile.default_mode: "profile"` + `profile.name: "example"`** — a persistent named
  profile, so the agent's home (config, history, memory) survives across runs. No `--profile`
  flag needed; it comes from the file.
- **`workspace.workdir: "."`** — the **entry folder**. The agent's shell starts in this
  folder (here, the workspace root). Set it to a subpath like `"services/api"` to drop the
  agent straight into a subdirectory; `--workdir <path>` overrides it for a single run.
- **`.envrc`** — the image ships `direnv` and runs its hook, so this file is loaded when the
  shell starts here. Run `direnv allow` once inside the container to trust it.

Every key maps to a CLI flag; the CLI always wins, so `agentdev --clean` or
`agentdev --workdir services/api` overrides the file for one run. See `DESIGN.md` §5 for the
full schema.
