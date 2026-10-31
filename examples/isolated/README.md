# Example: a locked-down headless run

A maximally locked-down profile — allowlist network with egress logging, a read-only workspace,
no SSH, an injected `.env`, and a kept agent home — for running an untrusted task or evaluating a
skill without giving the agent a way to touch the host, the network (beyond the model API), or your
credentials.

This folder is a whole **profile**: the launch config and the agent's home, side by side.

```text
isolated/
├── agentdev-config.json      the launch: workspace, network, home, one-shot
├── home/                     what the agent sees as ~ (mounted at /home/developer)
│   └── .claude/
│       ├── CLAUDE.md         instructions for every run of this profile
│       └── settings.json     Claude Code settings for this profile
├── work/                     the workspace (read-only to the agent)
└── .gitignore                keeps secrets, the task and run data out of git
```

```bash
cd examples/isolated
cp /path/to/secrets.env ./secret.env     # injected as .env; never inside work/ or home/
echo "do the task" > task.md
agentdev --dry-run                        # inspect the settled plan
agentdev                                  # runs claude headless on task.md, then exits
```

To use it on a real project, copy the folder somewhere of your own and point `workspace.source`
at the project (absolute, `~/…`, or relative to this folder):

```bash
cp -r examples/isolated ~/.agentdev/profiles/review
# edit ~/.agentdev/profiles/review/agentdev-config.json: "source": "~/src/my-project"
agentdev -c ~/.agentdev/profiles/review/agentdev-config.json
```

| Key | Value | Effect |
|---|---|---|
| `workspace.source` | `./work` | the project the agent works on; the profile's own files (home, secret, task) stay outside it |
| `workspace.mode` | `ro` | the agent **cannot modify** your project |
| `workspace.ssh` / `usb` | `false` | host SSH keys and USB are not passed in |
| `workspace.files` | `secret.env -> .env` | credentials injected without living in the project or the home |
| `network.mode` | `allowlist` | **only** `api.anthropic.com` is reachable, via a filtering proxy |
| `network.log` | `true` | every egress attempt is recorded to `home/agentdev-egress.log` |
| `mounts.agent_folder` | `./home` | this profile's home, kept across runs |
| `one-shot` | `claude` on `task.md` | runs headless, then exits |

Everything the agent writes into `home/` (sessions, `.claude.json` state, the egress log) is run
data and ignored by git; only the seed files above are tracked. agentdev creates `.claude.json`
itself on the first run.

Add hosts to `network.allow` to let more through (keep it minimal). Read the egress log with:

```bash
cut -f2,4 home/agentdev-egress.log | sort | uniq -c | sort -rn
```
