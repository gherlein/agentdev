# Example: a basic everyday profile with a few skills

A comfortable, persistent working profile that seeds three small skills into the agent's
home: `run-tests`, `git-commit`, and `review-diff`. This is the "just get to work" config —
normal networking, host SSH available, workspace writable — contrasted with the locked-down
[`../isolated`](../isolated) example.

```
basic-skills/
├── agentdev-config.json   # the config
└── template/              # the seed template this config points at
    ├── CLAUDE.md
    ├── settings.json
    ├── claude.json.seed
    └── skills/            # the "few basic skills"
        ├── run-tests/SKILL.md
        ├── git-commit/SKILL.md
        └── review-diff/SKILL.md
```

## Run it

```bash
cd examples/basic-skills
agentdev --dry-run     # inspect the plan
agentdev               # launch; seeds the skills into the "basic-skills" profile
```

Inside the container, `/skills` (and the agent's `~/.claude/skills`) hold the three skills;
ask the agent to "run the tests" or "review my diff" and it will use them.

## What the config does

- **`profile.default_mode: "profile"` + `profile.name: "basic-skills"`** — a persistent
  named profile, so history, memory, and these skills survive across runs.
- **`template.source: "./template"` + `template.include: ["CLAUDE.md", "settings.json", "skills"]`**
  — seeds the CLAUDE.md, settings, and the whole `skills/` directory from the bundled
  template. The skills live in the template, not the config; to add or remove one, edit
  `template/skills/` (each skill is a folder with a `SKILL.md`).
- **`network.mode: "off"`, `mounts.workspace: "rw"`, `sandbox.ssh: true`** — ordinary
  developer setup: normal networking, a writable workspace, and your host SSH keys mounted
  for git over SSH.
- **`auth.mode: "auto"`** — uses `$ANTHROPIC_API_KEY` if set, otherwise your host
  subscription login (inherited into this named profile).

> `template.source` is relative to where you launch, so run from inside this folder (or copy
> the folder into your project). Point it at an absolute path to use the same skills from
> anywhere.
