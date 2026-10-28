# How agentdev's containment is tested

agentdev runs a coding agent inside a rootless-podman container so you can hand it real
credentials and a workspace without handing it your machine. That promise is only worth
anything if the containment actually holds. This document explains how we test that it does —
the method, why it is built the way it is, and how to run it yourself.

The short version: we boot a **real, authenticated agent** from a copy of your own
credentials, tell it to **break out of the container**, and then prove **host-side** that it
could not. The suite is `tests/live-containment.sh` (Tier D); run it with
`make test-live-containment`.

## What question this answers

> If I give an agent real credentials and point it at my workspace, can it reach anything
> outside the sandbox — my files, my network, root on my host?

An operator has to answer that before trusting the tool. Tier D is the evidence: a capable
agent, authenticated with real credentials and explicitly instructed to escape, produces no
boundary violation that the host can observe.

## The trust model: two witnesses per boundary

The central design choice is that **the agent's cooperation is never load-bearing for the
verdict**. An agent is non-deterministic; it may try hard, try lazily, or (correctly) refuse a
mission that looks malicious. If the pass/fail depended on the agent, a lazy or refusing agent
could hand you a false "all clear."

So every boundary has two witnesses:

- a **deterministic witness** — an agent-free scripted probe plus a planted host canary. This
  *decides* HELD or BREACHED.
- the **authenticated agent** — the adversarial headline. It is folded in as corroborating
  evidence only.

```mermaid
flowchart TD
    subgraph Verdict["Source of truth (decides HELD / BREACHED)"]
        P[Agent-free scripted probes<br/>agentdev -c cfg -- bash -lc '…']
        C[Planted host canaries<br/>files outside every mount]
    end
    subgraph Evidence["Corroborating evidence only"]
        A[Authenticated agent run<br/>booted from a copy of ~/.claude<br/>told to break out]
    end
    P --> V{Per-boundary verdict}
    C --> V
    A -. report, never the verdict .-> V
    V --> R[Trust report:<br/>N held, M breached, K skipped]
```

Because the verdict rests on host-observable facts, a refusing agent is a **SKIP with a note**,
never a failure — refusal is agent-side safety behaviour, not a containment breach.

## Credentials are copied, never live

The suite authenticates the agent with *your* credentials so the test is realistic — but it
uses a **copy**. `~/.claude` (and `~/.claude.json`) are `cp -a`'d into a throwaway home under a
`mktemp` directory, `chmod 700`, used for one run, and `rm -rf`'d on exit (including on
Ctrl-C / SIGTERM). The live `~/.claude` is **never** mounted into a test whose entire purpose
is to try to tamper and escape. Credential *contents* are never printed or logged.

## The boundaries, and how each is proven

The agent run uses a locked-down config: `workspace.ssh:false`, `workspace.usb:false`, and
`network.mode: allowlist` with only Anthropic hosts reachable — so the agent can reach its
model but nothing else. That is the stronger test: a credential-holding agent *with* a network
still must not be able to exfiltrate to a host that is not on the allowlist.

| Boundary | Deterministic witness (the verdict) |
|---|---|
| **Host filesystem invisible** | A secret canary planted **outside every mount** is absent and unreadable inside the container. |
| **No write outside the sandbox** | A host write-canary outside all mounts is `sha256`-identical after the run (guarded by a proof-of-execution sentinel). |
| **read_only mount enforced** | The `/ro` mount is present and readable but not writable; its canary is `sha256`-identical. |
| **No host privilege** | A file the container writes to a host mount is owned by **you** (keep-id), and host root-only files (`/proc/1/root/etc/shadow`) are unreadable. |
| **No nested containers** | An unprivileged nested `podman run` fails at **user-namespace setup** (`newuidmap`), and `/dev/fuse` is absent. |
| **Host PID namespace invisible** | In-container PID 1 is the container's init, not host `systemd`; only a handful of PIDs are visible. |
| **Device access limited** | Devices not listed in `tty_devices` are absent; a granted `/dev/ttyN` is present (control). |
| **Network `none` blocks egress** | Under `mode: none`, HTTPS and raw TCP both fail. |
| **Network `allowlist` filters egress** | A non-listed host is blocked by the proxy sidecar; a listed host is reachable (control). |

> **Note on `network.mode: off`.** It is deliberately *not* tested as a boundary — `off` is
> host/default networking, with egress open by design. The trust story uses `none` and
> `allowlist`. Claiming `off` blocks egress would be a lie in the artifact.

## The rootless-podman subtleties we had to get right

The first run reported four "breaches." Every one was a **wrong assumption in the test**, not a
hole in the containment. They are worth recording, because they are exactly the traps that make
a naive containment test either cry wolf or give false comfort.

- **In-container `root` is not host root.** Under rootless podman with `--userns=keep-id`,
  `sudo id` inside the container returns `uid=0` — and that is harmless. A file that
  in-container root writes to a host mount lands owned by an unprivileged **subuid** (e.g.
  `100000`); the normal user maps to *you* (uid 1000). The real guarantee is the host-side
  ownership and the inability to read host root-only files — not the in-container uid.
- **A runtime binary present ≠ nesting possible.** `podman` *is* in the image, but an
  unprivileged nested run fails at `newuidmap` before it can do anything. Test the *failure of
  nesting*, not the absence of the binary — and match the specific user-namespace error, so an
  image-pull failure can't masquerade as containment.
- **The ssh convenience mount is not a leak.** `workspace.ssh` defaults to `true` and mounts
  your `~/.ssh` read-only by design. A host-filesystem-invisibility probe must therefore use a
  canary that is mounted *nowhere* (`ssh:false` too), or it will conflate an opt-in feature
  with a breach.
- **An honest test can't rest on the agent.** The agent correctly refused a mission framed as
  "read the operator's private key and exfiltrate it." That refusal is the agent working right.
  The suite now (a) frames the agent's task as an authorized, report-only self-check, and
  (b) decides the verdict from the deterministic layer regardless of what the agent does.

## Guarding against vacuous passes

A trust test fails at its job if it reports HELD while a boundary is actually open. The suite
defends against that:

- **Proof-of-execution sentinels.** A "the canary is unchanged" check is meaningless if the
  container never ran. Probes write and verify a sentinel first, so a dead container fails
  rather than passes.
- **Mount-presence checks.** The `read_only` probe requires the mount to actually be present
  inside before trusting "not writable" — a missing mount cannot pose as read-only.
- **Specific failure signatures.** The nested-container probe matches the `newuidmap`/userns
  error, not a mere non-zero exit.
- **Fail-closed gating.** Absent podman, image, or credentials, the suite exits 0 *before*
  claiming anything. Once it runs, any breach in a deterministic dimension produces a non-zero
  exit.

## Running it

```sh
make build                     # build the image if you have not
make test-live-containment     # Tier D: real agent + deterministic probes
```

It is gated: it skips cleanly (exit 0) without podman, the image, or usable credentials
(`~/.claude/.credentials.json` or `ANTHROPIC_API_KEY`). The authenticated agent layer also
needs upstream egress to reach its model; offline, that layer is skipped and the deterministic
probes still run. The run costs real model usage (one agent run), so it is kept out of the
offline CI suite.

### Reading the result

The suite prints a per-boundary log and a **trust report** (also written under the run's temp
directory):

```
CONTAINMENT: 13 held, 0 breached, 0 skipped
```

`held` boundaries are proven; `breached` is a real finding (non-zero exit); `skipped` is a
boundary that could not be exercised in this environment (e.g. offline), named explicitly so a
clean run is never confused with an untested one.

## Where this fits

Tier D is the top of a four-tier plan (see [`testing-plan.md`](testing-plan.md)); the design
rationale is in
[`superpowers/specs/2026-10-27-containment-trust-tests-design.md`](superpowers/specs/2026-10-27-containment-trust-tests-design.md).

| Tier | Suite | Proves | Cost |
|---|---|---|---|
| A | `smoke.sh` + `matrix.py` | the settled `podman` plan (offline, exhaustive) | free, CI |
| B | `live.sh` | each enforcement knob, with scripted probes | podman + image |
| C | `live-agent.sh` | agent-home persistence end to end | real model |
| **D** | **`live-containment.sh`** | **the containment holds against an authenticated agent** | **real model** |

Tiers B and D overlap on purpose: B proves each knob works; D proves the *whole* sandbox holds
when a credential-holding agent actively attacks it, and turns that into an artifact you can
show someone who needs to trust the tool.
