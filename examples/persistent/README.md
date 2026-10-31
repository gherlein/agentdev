# Example: a persistent home with split history and memory

This folder is a whole **profile**: the launch config and the agent's home, side by side.
`mounts.agent_folder` keeps the agent's home (config + identity) across runs. Setting
`mounts.history` and `mounts.memory` redirects *this run's* transcripts and memory to their own
folders, so you can keep one home for config while keeping history and memory separate for later
analysis.

```text
persistent/
├── agentdev-config.json      the launch: workspace and the three mounts
├── home/                     what the agent sees as ~ (mounted at /home/developer)
│   └── .claude/
│       ├── CLAUDE.md         instructions for every session of this profile
│       └── settings.json     Claude Code settings for this profile
├── history/                  transcripts (created on first run; git-ignored)
├── memory/                   memory (created on first run; git-ignored)
├── work/                     the workspace
└── .gitignore
```

```bash
cd examples/persistent
agentdev --dry-run     # inspect the plan
agentdev               # interactive; run `claude` inside
```

A persistent profile belongs somewhere of your own, not in a checkout. Copy it, then point
`workspace.source` at your project (absolute, `~/…`, or relative to this folder):

```bash
cp -r examples/persistent ~/.agentdev/profiles/myproject
# edit ~/.agentdev/profiles/myproject/agentdev-config.json: "source": "~/src/my-project"
agentdev -c ~/.agentdev/profiles/myproject/agentdev-config.json
```

Every path in the config is relative to the config file, so the copied profile keeps working
wherever you put it. Omit `agent_folder`, `history` and `memory` for a clean, ephemeral run.

Credentials: put a `.env` (or `.envrc`) in the workspace, or add `"host_login": true` to reuse
your host claude login.
