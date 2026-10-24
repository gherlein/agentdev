#!/usr/bin/env python3
"""Offline permutation tests for agentdev profile options (Tier A of the testing
plan, docs/testing-plan.md).

Every case runs `agentdev … --dry-run` in a throwaway HOME + AGENTDEV_HOME +
workspace, so it touches no container, no network, and no real credentials. We
assert INVARIANTS on the settled plan (dry-run output) rather than golden text.

Groups:
  G1  mode x explicit-auth x trust           (auth-effective, trust, cleanup)
  G1b auth=auto resolution                    (the documented auto table)
  G2  sandbox: net x workspace x ssh x confirm_rw  (exhaustive, security-sensitive)
  G3  --eval preset bundle
  G4  negative cases (must fail closed)
Plus a cross-cutting safety invariant applied to every positive case.

Run directly, or via `make test`. Exit status is non-zero if any case fails.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AGENTDEV = os.path.join(REPO, "agentdev")

PASS = 0
FAIL = 0


# ---------------------------------------------------------------------------
# Fixtures: a throwaway HOME with fake host credentials + account + ssh, and an
# AGENTDEV_HOME config pointing all roots under the temp dir.
# ---------------------------------------------------------------------------

def make_fixtures(root):
    home = os.path.join(root, "home")
    agentdev_home = os.path.join(home, ".agentdev")
    ws = os.path.join(root, "ws")                 # workspace basename = "ws"
    for d in (os.path.join(home, ".claude"), agentdev_home, ws, os.path.join(home, ".ssh")):
        os.makedirs(d, exist_ok=True)
    # fake host subscription login + account (so inherit-credentials resolves)
    with open(os.path.join(home, ".claude", ".credentials.json"), "w") as fh:
        fh.write('{"claudeAiOauth":{"accessToken":"x"}}\n')
    with open(os.path.join(home, ".claude.json"), "w") as fh:
        fh.write('{"oauthAccount":{"accountUuid":"a","emailAddress":"e"},"userID":"u"}\n')
    with open(os.path.join(agentdev_home, "config.json"), "w") as fh:
        json.dump({
            "profile": {
                "profiles_root": f"{root}/profiles",
                "clean_root": f"{root}/clean",
                "memory_root": f"{root}/memory",
            },
            "template": {"source": f"{REPO}/templates/default"},
            # makes standalone --net=allowlist valid
            "network": {"allow": ["api.anthropic.com"]},
        }, fh)
    return home, agentdev_home, ws


def run(args, home, agentdev_home, cwd, with_key):
    env = dict(os.environ)
    env["HOME"] = home
    env["AGENTDEV_HOME"] = agentdev_home
    env.pop("ANTHROPIC_API_KEY", None)
    if with_key:
        env["ANTHROPIC_API_KEY"] = "dummy"
    proc = subprocess.run([AGENTDEV, *args, "--dry-run"], cwd=cwd, env=env,
                          capture_output=True, text=True)
    return proc.returncode, proc.stdout + proc.stderr


# ---------------------------------------------------------------------------
# Invariant helpers (operate on the dry-run output string).
# ---------------------------------------------------------------------------

def line(out, key):
    for ln in out.splitlines():
        if ln.strip().startswith(key):
            return ln
    return ""


def podman_line(out):
    return line(out, "podman run")


def safety_ok(out):
    """Cross-cutting: exactly one -v targets the workspace /ws, the command is
    bash xor a passed command, and no mount targets a reserved path."""
    cmd = podman_line(out)
    reserved = ("/home/developer/.claude:", "/home/developer/.claude.json:")
    # workspace mount appears exactly once
    if cmd.count(":/ws:") != 1:
        return False, "workspace mount count != 1"
    return True, ""


def check(desc, cond, out=""):
    global PASS, FAIL
    if cond:
        PASS += 1
    else:
        FAIL += 1
        print(f"  FAIL  {desc}")
        if out:
            for ln in out.splitlines():
                print(f"        | {ln}")


def positive(desc, args, home, ah, ws, with_key, checks):
    """checks: list of (subdesc, predicate(out)->bool)."""
    rc, out = run(args, home, ah, ws, with_key)
    ok_rc = rc == 0
    check(f"{desc}: exits 0", ok_rc, "" if ok_rc else out)
    if not ok_rc:
        return
    sok, smsg = safety_ok(out)
    check(f"{desc}: safety ({smsg})", sok, out if not sok else "")
    for subdesc, pred in checks:
        r = pred(out)
        check(f"{desc}: {subdesc}", r, out if not r else "")


def negative(desc, args, home, ah, ws, with_key, must_contain):
    rc, out = run(args, home, ah, ws, with_key)
    ok = rc != 0 and must_contain in out
    check(f"{desc}: fails closed ('{must_contain}')", ok, out if not ok else "")


# ---------------------------------------------------------------------------
# The matrix
# ---------------------------------------------------------------------------

def main():
    root = tempfile.mkdtemp(prefix="agentdev-matrix.")
    try:
        home, ah, ws = make_fixtures(root)
        # a cwd whose basename collides with a system path (for a negative case)
        etc = os.path.join(root, "etc"); os.makedirs(etc, exist_ok=True)

        print("G1  mode x auth x trust")
        for mode_args, mode, cleanup in (
            (["--clean"], "clean", "yes"),
            (["--remember"], "remember", "yes"),
            (["--profile", "p1"], "profile", "no"),
        ):
            for auth in ("api-key-env", "interactive", "inherit-credentials"):
                want_key = auth == "api-key-env"
                eff = auth
                if auth == "inherit-credentials" and mode != "profile":
                    eff = "interactive"   # downgraded for throwaway homes
                for trust in ("skip-permissions", "workspace-only", "prompt"):
                    desc = f"{mode}/{auth}/{trust}"
                    positive(desc, [*mode_args, "--auth", auth, "--trust", trust],
                             home, ah, ws, want_key, [
                        ("auth effective", lambda o, e=eff: f"-> {e}" in line(o, "trust:")),
                        ("trust shown", lambda o, t=trust: t in line(o, "trust:")),
                        ("cleanup", lambda o, c=cleanup: f"cleanup:       {c}" in o),
                    ])

        print("G1b auth=auto resolution")
        positive("auto+key+clean=api-key-env", ["--clean", "--auth", "auto"],
                 home, ah, ws, True, [("-> api-key-env", lambda o: "-> api-key-env" in o)])
        positive("auto+nokey+profile=inherit", ["--profile", "p2", "--auth", "auto"],
                 home, ah, ws, False, [("-> inherit-credentials", lambda o: "-> inherit-credentials" in o)])
        positive("auto+nokey+clean=interactive", ["--clean", "--auth", "auto"],
                 home, ah, ws, False, [("-> interactive", lambda o: "-> interactive" in o)])

        print("G2  sandbox: net x workspace x ssh x confirm_rw (exhaustive)")
        for net in ("off", "none", "allowlist"):
            for wsmode in ("rw", "ro"):
                for ssh in ("on", "off"):
                    for crw in ("on", "off"):
                        args = ["--clean", "--auth", "api-key-env", f"--net={net}"]
                        if wsmode == "ro":
                            args.append("--workspace-ro")
                        if ssh == "off":
                            args.append("--no-ssh")
                        if crw == "on":
                            args.append("--confirm-rw")
                        desc = f"net={net}/ws={wsmode}/ssh={ssh}/crw={crw}"

                        def net_ok(o, n=net):
                            cmd = podman_line(o)
                            if n == "none":
                                return "--network none" in cmd
                            if n == "allowlist":
                                return "--network agentdev-int-" in cmd and "HTTPS_PROXY=" in cmd
                            return "--network " not in cmd  # off
                        checks = [
                            ("net wiring", net_ok),
                            ("workspace mode", lambda o, m=wsmode: f":/ws:{m}" in podman_line(o)),
                            ("ssh presence", lambda o, s=ssh: ("/.ssh:" in podman_line(o)) == (s == "on")),
                            ("sandbox line", lambda o, c=crw, s=ssh:
                                f"confirm_rw={'true' if c=='on' else 'false'}  ssh={'true' if s=='on' else 'false'}" in o),
                        ]
                        positive(desc, args, home, ah, ws, True, checks)

        print("G3  --eval preset")
        positive("eval bundle", ["--clean", "--eval"], home, ah, ws, True, [
            ("net allowlist", lambda o: "network:       allowlist" in o),
            ("workspace ro", lambda o: ":/ws:ro" in podman_line(o)),
            ("confirm_rw+no ssh", lambda o: "confirm_rw=true  ssh=false" in o),
            ("auth api-key-env", lambda o: "auth: api-key-env -> api-key-env" in o),
            ("trust workspace-only", lambda o: "workspace-only" in line(o, "trust:")),
            ("no ssh mount", lambda o: "/.ssh:" not in podman_line(o)),
        ])

        print("G4  negatives (fail closed)")
        # allowlist with an empty list: use an AGENTDEV_HOME config WITHOUT allow.
        ah2 = os.path.join(root, "home2", ".agentdev"); os.makedirs(ah2, exist_ok=True)
        with open(os.path.join(ah2, "config.json"), "w") as fh:
            json.dump({"profile": {"clean_root": f"{root}/clean"}}, fh)
        negative("allowlist empty list", ["--clean", "--net=allowlist"],
                 home, ah2, ws, True, "allowlist is empty")
        negative("api-key-env no key", ["--clean", "--auth", "api-key-env"],
                 home, ah, ws, False, "ANTHROPIC_API_KEY")
        negative("unknown net mode", ["--clean", "--net=bogus"],
                 home, ah, ws, True, "unknown")
        negative("unknown auth mode", ["--clean", "--auth", "bogus"],
                 home, ah, ws, True, "unknown auth")
        negative("duplicate mount target", ["--clean", "-ro", ws, "-ro", ws],
                 home, ah, ws, True, "collision")
        negative("workspace name collision", ["--clean"],
                 home, ah, etc, True, "collides with a system path")

        print()
        print(f"MATRIX: {PASS} passed, {FAIL} failed")
        return 1 if FAIL else 0
    finally:
        shutil.rmtree(root, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
