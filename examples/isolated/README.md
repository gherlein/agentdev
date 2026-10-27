# Example: a locked-down headless run

A maximally locked-down config — allowlist network with egress logging, a read-only workspace, no
SSH, an injected `.env`, and a kept agent home — for running an untrusted task or evaluating a
skill without giving the agent a way to touch the host, the network (beyond the model API), or your
credentials.

```bash
cd examples/isolated
cp /path/to/secrets.env ./secret.env     # injected as .env (add secret.env to .gitignore)
echo "do the task" > task.md
agentdev --dry-run                        # inspect the settled plan
agentdev                                  # runs claude headless on task.md, then exits
```

| Key | Value | Effect |
|---|---|---|
| `workspace.mode` | `ro` | the agent **cannot modify** your project |
| `workspace.ssh` / `usb` | `false` | host SSH keys and USB are not passed in |
| `workspace.files` | `secret.env -> .env` | credentials injected without living in the repo |
| `network.mode` | `allowlist` | **only** `api.anthropic.com` is reachable, via a filtering proxy |
| `network.log` | `true` | every egress attempt is recorded to `<agent_folder>/agentdev-egress.log` |
| `mounts.agent_folder` | `./.agent-home` | a kept home, so the egress log persists |
| `one-shot` | `claude` on `task.md` | runs headless, then exits |

Add hosts to `network.allow` to let more through (keep it minimal). Read the egress log with:

```bash
cut -f2,4 .agent-home/agentdev-egress.log | sort | uniq -c | sort -rn
```
