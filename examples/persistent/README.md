# Example: a persistent home with split history and memory

`mounts.agent_folder` keeps the agent's home (config + identity) across runs. Setting
`mounts.history` and `mounts.memory` redirects *this run's* transcripts and memory to their
own host folders, so you can reuse one home for config while keeping each run's history and
memory separate for later analysis. Omit all three for a clean, ephemeral run.

```bash
cd examples/persistent
agentdev --dry-run     # inspect the plan
agentdev               # interactive; run `claude` inside
```
