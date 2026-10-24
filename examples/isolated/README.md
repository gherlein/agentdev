# Example: a very isolated profile

A maximally locked-down config — the same posture as `agentdev --eval`, spelled out so you
can see and tune every control. Use it to run untrusted code or evaluate a skill without
giving the agent a way to touch the host, the network (beyond the model API), or your
credentials.

## Run it

```bash
cd examples/isolated
agentdev --dry-run     # inspect the settled plan first
agentdev               # launch (needs the image; see `make build`)
```

or point at it from your own project directory:

```bash
agentdev -c /path/to/examples/isolated/agentdev-config.json
```

## What makes it isolated

| Key | Value | Effect |
|---|---|---|
| `profile.default_mode` | `clean` | throwaway home, **discarded on exit** — nothing persists |
| `auth.mode` | `api-key-env` | uses only `$ANTHROPIC_API_KEY`; never inherits your host login/credentials |
| `workspace.trust` | `workspace-only` | no blanket permission skip; trust is scoped to the workspace |
| `network.mode` | `allowlist` | **only** `api.anthropic.com` is reachable, via a filtering proxy; everything else is blocked |
| `network.log` | `true` | every egress attempt is recorded (`agentdev report <profile>`) |
| `mounts.workspace` | `ro` | the agent **cannot modify** your working directory |
| `mounts.confirm_rw` | `true` | any read-write mount must be confirmed (fail-closed with no TTY) |
| `sandbox.ssh` | `false` | host SSH keys / agent socket are **not** mounted |
| `template.include` | `CLAUDE.md`, `settings.json` | seeds only the essentials — no hooks, skills, or MCP servers |

To let a specific host through, add it to `network.allow` (e.g. `"registry.npmjs.org:443"`).
To let the agent write to one directory, add it under `mounts.read_write` and/or
`mounts.rw_allow`. Keep both lists minimal.

Requires `$ANTHROPIC_API_KEY` in the environment (no subscription login is used).
