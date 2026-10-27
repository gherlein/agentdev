# Example: minimal interactive config

The smallest sensible config — mount the current folder as the workspace and launch an interactive
shell. No `agent_folder` is mounted, so the home is ephemeral and discarded on exit.

```bash
cd examples/minimal
agentdev --dry-run     # inspect the plan
agentdev               # a shell; run `claude` inside
```

Put credentials in a `.env` (or `.envrc`) in this folder, e.g. `ANTHROPIC_API_KEY=sk-ant-...`; the
agent loads it. To persist the agent's home across runs, add
`"mounts": { "agent_folder": "./.agent-home" }`.
