#!/usr/bin/env python3
"""Offline permutation tests for the agentdev config schema (Tier A of the testing
plan). Each case writes one config and runs `agentdev -c <file> --dry-run` in a
throwaway HOME + workspace, asserting invariants on the settled plan. No container,
no network, no real credentials.

Groups:
  G1  interactive vs one-shot
  G2  workspace (mount, mode, ssh/usb, files)
  G3  mounts (agent_folder, read_only/read_write, history/memory, tty_devices)
  G4  network (off / none / allowlist)
  G5  negatives (fail closed)

Run directly or via `make test`. Exit status is non-zero if any case fails.
"""
import json
import os
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AGENTDEV = os.path.join(REPO, "agentdev")
PASS = 0
FAIL = 0


def make_fixtures(root):
    home = os.path.join(root, "home")
    ws = os.path.join(root, "ws")
    for name in ("home", "ws", "ref", "out", "ahome", "hist", "mem"):
        os.makedirs(os.path.join(root, name), exist_ok=True)
    with open(os.path.join(root, "task.md"), "w") as fh:   # prompt at the config dir
        fh.write("do the thing\n")
    with open(os.path.join(root, "secret.env"), "w") as fh:
        fh.write("ANTHROPIC_API_KEY=x\n")
    return home, ws


def run(config, root, home):
    path = os.path.join(root, "case.json")
    with open(path, "w") as fh:
        json.dump(config, fh)
    env = dict(os.environ)
    env["HOME"] = home
    env.pop("AGENTDEV_CONFIG", None)
    proc = subprocess.run([AGENTDEV, "-c", path, "--dry-run"], cwd=root, env=env,
                          capture_output=True, text=True)
    return proc.returncode, proc.stdout + proc.stderr


def check(desc, cond, out=""):
    global PASS, FAIL
    if cond:
        PASS += 1
    else:
        FAIL += 1
        print(f"  FAIL  {desc}")
        for ln in out.splitlines():
            print(f"        | {ln}")


def line(out, key):
    for ln in out.splitlines():
        if ln.strip().startswith(key):
            return ln
    return ""


def podman_line(out):
    return line(out, "podman run")


def positive(desc, cfg, root, home, checks):
    rc, out = run(cfg, root, home)
    ok = rc == 0
    check(f"{desc}: exits 0", ok, "" if ok else out)
    if not ok:
        return
    for sub, pred in checks:
        r = pred(out)
        check(f"{desc}: {sub}", r, out if not r else "")


def negative(desc, cfg, root, home, must):
    rc, out = run(cfg, root, home)
    ok = rc != 0 and must in out
    check(f"{desc}: fails ('{must}')", ok, out if not ok else "")


def main():
    root = tempfile.mkdtemp(prefix="agentdev-matrix.")
    try:
        home, ws = make_fixtures(root)
        P = lambda *a: os.path.join(root, *a)
        base = {"workspace": {"source": ws, "mount": "work"}}

        print("G1  interactive vs one-shot")
        positive("interactive default", dict(base), root, home, [
            ("run mode interactive", lambda o: "run mode:      interactive" in o),
            ("command ends in bash", lambda o: podman_line(o).rstrip().endswith(" bash")),
            ("no prompt mount", lambda o: "/.agentdev-prompt" not in o),
        ])
        for agent, model in (("claude", "claude-opus-5-5"), ("omp", ""), ("pi", "")):
            cfg = {**base, "one-shot": {"agent": agent, "prompt": "task.md"}}
            if model:
                cfg["one-shot"]["model"] = model
            want_env = agent == "claude" and bool(model)
            positive(f"one-shot/{agent}", cfg, root, home, [
                ("run mode one-shot", lambda o: "run mode:      one-shot" in o),
                (f"agent {agent}", lambda o, a=agent: f"agent:         {a}" in o),
                ("prompt mounted ro", lambda o: "/.agentdev-prompt:ro" in o),
                # the bash -lc command is %q-escaped in the plan, so spaces print as "\ ".
                (f"headless {agent} built", lambda o, a=agent: (a + "\\ ") in podman_line(o)),
                ("model env", lambda o, w=want_env: ("ANTHROPIC_MODEL=" in o) == w),
            ])

        print("G2  workspace")
        positive("mount name -> /name and workdir", {"workspace": {"source": ws, "mount": "proj"}},
                 root, home, [
            ("mounts at /proj", lambda o: ":/proj:rw" in podman_line(o)),
            ("-w /proj", lambda o: "-w /proj" in podman_line(o)),
            ("enc -proj", lambda o: "enc: -proj" in o),
        ])
        positive("mount defaults to basename", {"workspace": {"source": ws}}, root, home, [
            ("mounts at /ws", lambda o: ":/ws:rw" in podman_line(o)),
        ])
        positive("mode ro", {"workspace": {"source": ws, "mount": "work", "mode": "ro"}}, root, home, [
            ("workspace ro", lambda o: ":/work:ro" in podman_line(o)),
        ])
        positive("ssh/usb off", {"workspace": {"source": ws, "mount": "work", "ssh": False, "usb": False}},
                 root, home, [
            ("no .ssh mount", lambda o: "/.ssh:" not in podman_line(o)),
            ("no usb device", lambda o: "/dev/bus/usb" not in podman_line(o)),
        ])
        positive("workspace.files inject", {"workspace": {"source": ws, "mount": "work",
                 "files": [{"source": P("secret.env"), "name": ".env"}]}}, root, home, [
            ("file bound ro into /work", lambda o: ":/work/.env:ro" in podman_line(o)),
        ])

        print("G3  mounts")
        positive("agent_folder home mounts", {**base, "mounts": {"agent_folder": P("ahome")}},
                 root, home, [
            ("home shown", lambda o: f"agent home:    {P('ahome')}" in o),
            (".claude mounted", lambda o: ":/home/developer/.claude:rw" in podman_line(o)),
            (".claude.json mounted", lambda o: ":/home/developer/.claude.json:rw" in podman_line(o)),
            ("--name + home label", lambda o: "--name agentdev-" in podman_line(o) and "agentdev.home=" in podman_line(o)),
        ])
        positive("ephemeral home when omitted", dict(base), root, home, [
            ("ephemeral", lambda o: "ephemeral" in line(o, "agent home:")),
            ("no home mount", lambda o: ":/home/developer/.claude:" not in podman_line(o)),
        ])
        positive("read_only/read_write pairs", {**base, "mounts": {
                 "read_only": [{"src": P("ref"), "dest": "/ref"}],
                 "read_write": [{"src": P("out"), "dest": "/out"}]}}, root, home, [
            ("ref ro", lambda o: f"{P('ref')}:/ref:ro" in podman_line(o)),
            ("out rw", lambda o: f"{P('out')}:/out:rw" in podman_line(o)),
        ])
        positive("claude history+memory redirect", {**base, "mounts": {
                 "history": P("hist"), "memory": P("mem")}}, root, home, [
            ("history to projects/-work", lambda o: f"{P('hist')}:/home/developer/.claude/projects/-work:rw" in podman_line(o)),
            ("memory to .../memory", lambda o: f"{P('mem')}:/home/developer/.claude/projects/-work/memory:rw" in podman_line(o)),
        ])
        positive("omp memory redirect", {**base, "mounts": {"memory": P("mem")},
                 "one-shot": {"agent": "omp", "prompt": "task.md"}}, root, home, [
            ("memory to omp memories", lambda o: f"{P('mem')}:/home/developer/.omp/agent/memories:rw" in podman_line(o)),
        ])
        import glob
        ttys = [d for d in glob.glob("/dev/tty[0-9]") + glob.glob("/dev/ttyS[0-9]")
                if os.path.exists(d)]
        if ttys:
            dev = ttys[0]
            positive("tty_devices", {**base, "mounts": {"tty_devices": [dev]}}, root, home, [
                ("device passed", lambda o, d=dev: f"--device {d}" in podman_line(o)),
            ])
        else:
            print("  skip  tty_devices (no /dev/ttyN device on this host)")

        print("G4  network")
        positive("off", dict(base), root, home, [
            ("network off", lambda o: "network:       off" in o),
            ("no proxy", lambda o: "HTTPS_PROXY" not in o),
        ])
        positive("none", {**base, "network": {"mode": "none"}}, root, home, [
            ("--network none", lambda o: "--network none" in podman_line(o)),
        ])
        positive("allowlist", {**base, "network": {"mode": "allowlist", "allow": ["api.anthropic.com"], "log": True}},
                 root, home, [
            ("proxy env", lambda o: "HTTPS_PROXY=http://agentdev-proxy-" in podman_line(o)),
            ("internal net", lambda o: "--network agentdev-int-" in podman_line(o)),
            ("allow printed", lambda o: "api.anthropic.com" in o),
        ])

        print("G5  negatives (fail closed)")
        negative("unknown key", {**base, "bogus": 1}, root, home, "bogus: unknown key")
        negative("retired profile", {**base, "profile": {"mode": "clean"}}, root, home,
                 "profile: removed")
        negative("retired auth", {**base, "auth": {"mode": "auto"}}, root, home, "auth: removed")
        negative("bad enum", {**base, "network": {"mode": "nope"}}, root, home, "must be one of")
        negative("read_only as map", {**base, "mounts": {"read_only": {"a": "/b"}}}, root, home,
                 "must be a list of { src, dest }")
        negative("tty not tty", {**base, "mounts": {"tty_devices": ["/dev/bus/usb"]}}, root, home,
                 "must be a /dev/ttyX")
        negative("pi + memory", {**base, "mounts": {"memory": P("mem")},
                 "one-shot": {"agent": "pi", "prompt": "task.md"}}, root, home,
                 "no separable memory folder")
        negative("omp + history", {**base, "mounts": {"history": P("hist")},
                 "one-shot": {"agent": "omp", "prompt": "task.md"}}, root, home,
                 "no separable history folder")
        negative("one-shot no prompt", {**base, "one-shot": {"agent": "claude"}}, root, home,
                 "needs a prompt")
        negative("mount name with slash", {"workspace": {"source": ws, "mount": "a/b"}}, root, home,
                 "single path segment")
        negative("system-path mount name", {"workspace": {"source": ws, "mount": "etc"}}, root, home,
                 "collides with a system path")
        negative("missing read_only source", {**base, "mounts": {"read_only": [{"src": P("nope"), "dest": "/x"}]}},
                 root, home, "not an existing directory")

        print(f"\nMATRIX: {PASS} passed, {FAIL} failed")
        return 1 if FAIL else 0
    finally:
        import shutil
        shutil.rmtree(root, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
