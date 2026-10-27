#!/usr/bin/env python3
"""Offline permutation tests for agentdev config options (Tier A of the testing
plan, docs/testing-plan.md).

Every case writes one agentdev config file and runs `agentdev -c <file> --dry-run`
in a throwaway HOME + workspace, so it touches no container, no network, and no
real credentials. We assert INVARIANTS on the settled plan (dry-run output) rather
than golden text.

Groups:
  G1  mode x explicit-auth x trust           (auth-effective, trust, cleanup)
  G1b auth=auto resolution                    (the documented auto table)
  G2  sandbox: net x workspace x ssh x confirm_rw  (exhaustive, security-sensitive)
  G3  locked-down config (examples/isolated)
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
# Fixtures: a throwaway HOME with fake host credentials + account + ssh, and a
# base config pointing all roots under the temp dir.
# ---------------------------------------------------------------------------

def make_fixtures(root):
    home = os.path.join(root, "home")
    ws = os.path.join(root, "ws")                 # workspace basename = "ws"
    for d in (os.path.join(home, ".claude"), ws, os.path.join(home, ".ssh")):
        os.makedirs(d, exist_ok=True)
    # fake host subscription login + account (so inherit-credentials resolves)
    with open(os.path.join(home, ".claude", ".credentials.json"), "w") as fh:
        fh.write('{"claudeAiOauth":{"accessToken":"x"}}\n')
    with open(os.path.join(home, ".claude.json"), "w") as fh:
        fh.write('{"oauthAccount":{"accountUuid":"a","emailAddress":"e"},"userID":"u"}\n')
    return home, ws


def merge(base, extra):
    for key, value in extra.items():
        if isinstance(value, dict) and isinstance(base.get(key), dict):
            merge(base[key], value)
        else:
            base[key] = value
    return base


def base_config(root, ws):
    return {
        "profile": {
            "profiles_root": f"{root}/profiles",
            "clean_root": f"{root}/clean",
            "memory_root": f"{root}/memory",
        },
        "template": {"source": f"{REPO}/templates/default"},
        "workspace": {"source": ws},
    }


def run(config, root, home, with_key):
    path = os.path.join(root, "case-config.json")
    with open(path, "w") as fh:
        json.dump(config, fh)
    env = dict(os.environ)
    env["HOME"] = home
    env.pop("ANTHROPIC_API_KEY", None)
    if with_key:
        env["ANTHROPIC_API_KEY"] = "dummy"
    proc = subprocess.run([AGENTDEV, "-c", path, "--dry-run"], cwd=root, env=env,
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
    """Cross-cutting: exactly one -v targets the workspace /ws, and the API key value
    never appears in the plan."""
    cmd = podman_line(out)
    if cmd.count(":/ws:") != 1:
        return False, "workspace mount count != 1"
    if "ANTHROPIC_API_KEY=" in out:
        return False, "API key value printed"
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


def positive(desc, extra, ctx, with_key, checks):
    """checks: list of (subdesc, predicate(out)->bool)."""
    root, home, ws = ctx
    rc, out = run(merge(base_config(root, ws), extra), root, home, with_key)
    ok_rc = rc == 0
    check(f"{desc}: exits 0", ok_rc, "" if ok_rc else out)
    if not ok_rc:
        return
    sok, smsg = safety_ok(out)
    check(f"{desc}: safety ({smsg})", sok, out if not sok else "")
    for subdesc, pred in checks:
        result = pred(out)
        check(f"{desc}: {subdesc}", result, out if not result else "")


def negative(desc, extra, ctx, with_key, must_contain):
    root, home, ws = ctx
    rc, out = run(merge(base_config(root, ws), extra), root, home, with_key)
    ok = rc != 0 and must_contain in out
    check(f"{desc}: fails closed ('{must_contain}')", ok, out if not ok else "")


# ---------------------------------------------------------------------------
# The matrix
# ---------------------------------------------------------------------------

def main():
    root = tempfile.mkdtemp(prefix="agentdev-matrix.")
    try:
        home, ws = make_fixtures(root)
        ctx = (root, home, ws)
        # a workspace whose basename collides with a system path (negative case)
        etc = os.path.join(root, "etc"); os.makedirs(etc, exist_ok=True)

        print("G1  mode x auth x trust")
        for profile, mode, cleanup in (
            ({"mode": "clean"}, "clean", "yes"),
            ({"mode": "remember"}, "remember", "yes"),
            ({"mode": "profile", "name": "p1"}, "profile", "no"),
        ):
            for auth in ("api-key-env", "interactive", "inherit-credentials"):
                want_key = auth == "api-key-env"
                # inherit-credentials is refused fail-closed outside profile mode: a
                # throwaway home (clean/remember) must never hold a copied credential
                # (VISION §7), and an explicit auth.mode is never silently changed.
                refuse = auth == "inherit-credentials" and mode != "profile"
                for trust in ("skip-permissions", "workspace-only", "prompt"):
                    desc = f"{mode}/{auth}/{trust}"
                    cfg = {"profile": profile, "auth": {"mode": auth},
                           "workspace": {"trust": trust}}
                    if refuse:
                        negative(desc, cfg, ctx, want_key,
                                 "valid only with profile.mode=profile")
                        continue
                    positive(desc, cfg, ctx, want_key, [
                        ("auth effective", lambda o, e=auth: f"-> {e}" in line(o, "trust:")),
                        ("trust shown", lambda o, t=trust: t in line(o, "trust:")),
                        ("cleanup", lambda o, c=cleanup: f"cleanup:       {c}" in o),
                    ])

        print("G1b auth=auto resolution")
        positive("auto+key+clean=api-key-env", {"auth": {"mode": "auto"}},
                 ctx, True, [("-> api-key-env", lambda o: "-> api-key-env" in o)])
        positive("auto+nokey+profile=inherit",
                 {"profile": {"mode": "profile", "name": "p2"}, "auth": {"mode": "auto"}},
                 ctx, False, [("-> inherit-credentials", lambda o: "-> inherit-credentials" in o)])
        positive("auto+nokey+clean=interactive", {"auth": {"mode": "auto"}},
                 ctx, False, [("-> interactive", lambda o: "-> interactive" in o)])

        print("G2  sandbox: net x workspace x ssh x confirm_rw (exhaustive)")
        for net in ("off", "none", "allowlist"):
            for wsmode in ("rw", "ro"):
                for ssh in (True, False):
                    for confirm_rw in (True, False):
                        network = {"mode": net}
                        if net == "allowlist":
                            network["allow"] = ["api.anthropic.com"]
                        extra = {
                            "auth": {"mode": "api-key-env"},
                            "network": network,
                            "mounts": {"workspace": wsmode, "confirm_rw": confirm_rw},
                            "sandbox": {"ssh": ssh},
                        }
                        desc = f"net={net}/ws={wsmode}/ssh={ssh}/crw={confirm_rw}"

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
                            ("ssh presence", lambda o, s=ssh: ("/.ssh:" in podman_line(o)) == s),
                            ("sandbox line", lambda o, c=confirm_rw, s=ssh:
                                f"confirm_rw={str(c).lower()}  ssh={str(s).lower()}" in o),
                        ]
                        positive(desc, extra, ctx, True, checks)

        print("G3  locked-down config (examples/isolated)")
        with open(os.path.join(REPO, "examples", "isolated", "agentdev-config.json")) as fh:
            isolated = json.load(fh)
        isolated.pop("template", None)
        positive("isolated example", isolated, ctx, True, [
            ("net allowlist", lambda o: "network:       allowlist" in o),
            ("workspace ro", lambda o: ":/ws:ro" in podman_line(o)),
            ("confirm_rw+no ssh", lambda o: "confirm_rw=true  ssh=false" in o),
            ("no usb", lambda o: "usb=false" in o and "/dev/bus/usb" not in podman_line(o)),
            ("auth api-key-env", lambda o: "auth: api-key-env -> api-key-env" in o),
            ("trust workspace-only", lambda o: "workspace-only" in line(o, "trust:")),
            ("no ssh mount", lambda o: "/.ssh:" not in podman_line(o)),
        ])

        print("G4  negatives (fail closed)")
        negative("allowlist empty list", {"network": {"mode": "allowlist", "allow": []}},
                 ctx, True, "network.allow is empty")
        negative("allowlist without model endpoint",
                 {"network": {"mode": "allowlist", "allow": ["example.com"]}},
                 ctx, True, "does not allow the model endpoint")
        negative("api-key-env no key", {"auth": {"mode": "api-key-env"}},
                 ctx, False, "ANTHROPIC_API_KEY")
        negative("unknown net mode", {"network": {"mode": "bogus"}},
                 ctx, True, "network.mode: must be one of")
        negative("unknown auth mode", {"auth": {"mode": "bogus"}},
                 ctx, True, "auth.mode: must be one of")
        negative("unknown key", {"sandbox": {"sssh": False}},
                 ctx, True, "sandbox.sssh: unknown key")
        negative("duplicate mount target",
                 {"mounts": {"read_only": {ws: "/dup", ws + "/.": "/dup"}}},
                 ctx, True, "collision")
        negative("workspace name collision", {"workspace": {"source": etc}},
                 ctx, True, "collides with a system path")

        print()
        print(f"MATRIX: {PASS} passed, {FAIL} failed")
        return 1 if FAIL else 0
    finally:
        shutil.rmtree(root, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
