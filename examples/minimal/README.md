# Minimal config

The smallest sensible starting point: a clean-room Claude Code run in the current
directory, full network, host SSH/USB/CA passed through. Copy it and edit:

```bash
cp examples/minimal/agentdev-config.json ~/my-project/agentdev-config.json
cd ~/my-project
agentdev --dry-run     # check the plan
agentdev               # launch
```

Every key is documented in [`../../docs/user-guide.md`](../../docs/user-guide.md). To
start from here:

- Set `model.id` to pin a model (e.g. `"claude-opus-5-5"`).
- Switch `profile.mode` to `remember` (add `profile.memory_store`) or `profile` (add
  `profile.name`) to keep memory or everything across runs.
- Add host folders under `mounts.read_only` / `mounts.read_write`.
- Lock the network down with `network.mode: "allowlist"` (see
  [`../isolated`](../isolated)).
