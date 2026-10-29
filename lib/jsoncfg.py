#!/usr/bin/env python3
"""Tiny JSON reader and schema validator for the agentdev launcher.

The sole config reader: lib/config.sh and lib/mounts.sh descend into the grouped
agentdev-config.json with the verbs below.

Usage:
  jsoncfg.py get      <file> <dotted.key>          -> prints a scalar (exit 1 if missing/not scalar)
  jsoncfg.py list     <file> <dotted.key>          -> prints list items, one per line (exit 1 if missing)
  jsoncfg.py rows     <file> <dotted.key> <f ...>   -> for a list of objects, prints the named fields TAB-separated per row
  jsoncfg.py has      <file> <dotted.key>          -> exit 0 if the key is present, 1 if not
  jsoncfg.py check    <file>                        -> exit 0 if the file parses as JSON, else exit 3
  jsoncfg.py validate <file>                        -> exit 0 if the file matches SCHEMA, else exit 4 + every error

Exit codes: 0 ok; 1 missing/wrong-type; 2 file not found; 3 parse error; 4 schema error.

Keys starting with "//" are comments and are ignored at every level.
"""
import json
import re
import sys

TTY = re.compile(r"^/dev/tty[A-Za-z0-9]+$")

# Leaf types: "str", "bool", "str-list", a tuple of allowed strings (an enum),
# "pair-list" (list of {src,dest}), "file-list" (list of {source,name}), or
# "tty-list" (list of /dev/ttyX strings). A dict is a nested group.
SCHEMA = {
    "image": "str",
    "workspace": {
        "source": "str",
        "mount": "str",
        "mode": ("rw", "ro"),
        "ssh": "bool",
        "usb": "bool",
        "files": "file-list",
    },
    "network": {
        "mode": ("off", "none", "allowlist"),
        "allow": "str-list",
        "log": "bool",
        "mitm": "bool",
    },
    "mounts": {
        "agent_folder": "str",
        "read_only": "pair-list",
        "read_write": "pair-list",
        "history": "str",
        "memory": "str",
        "tty_devices": "tty-list",
    },
    "one-shot": {
        "agent": ("claude", "omp", "pi"),
        "model": "str",
        "prompt": "str",
    },
    "skills": {
        "store": "str",
        "profile": "str",
        "include": "str-list",
    },
    "mcp": "str-list",
    "host_login": "bool",
}

# Keys from earlier config versions, so a stale file gets a pointed message.
RETIRED = {
    "agent": "removed; the agent is now one-shot.agent (a short name: claude | omp | pi)",
    "model": "removed; the model is now one-shot.model (routing via .env/.envrc)",
    "prompt": "removed; use one-shot.prompt or the --prompt flag",
    "profile": "removed; mount the agent home with mounts.agent_folder (no modes)",
    "template": "removed; copy a starter kit from templates/<agent>/ by hand",
    "auth": "removed; credentials come from a .env/.envrc in the workspace",
    "sandbox": "removed; ssh/usb moved to workspace.ssh / workspace.usb (host_ca dropped)",
    "workspace.workdir": "removed; the agent starts at the workspace root",
    "workspace.trust": "removed; one-shot runs skip permissions, interactive runs decide inside",
    "mounts.devices": "renamed to mounts.tty_devices (each must be /dev/ttyX)",
    "mounts.confirm_rw": "removed",
    "mounts.rw_allow": "removed",
    "mounts.workspace": "removed; the workspace mount mode is workspace.mode",
    "mounts.copy_files": "removed; inject files with workspace.files",
}

PAIR_KEYS = {"pair-list": ("src", "dest"), "file-list": ("source", "name")}


def load(path):
    try:
        with open(path, "rb") as fh:
            return json.load(fh)
    except FileNotFoundError:
        sys.exit(2)
    except (json.JSONDecodeError, ValueError) as exc:
        sys.stderr.write(f"error: {path}: invalid JSON: {exc}\n")
        sys.exit(3)


def is_comment(key):
    return key.startswith("//")


def check_leaf(path, kind, value, errors):
    if isinstance(kind, tuple):
        if not isinstance(value, str) or value not in kind:
            errors.append(f"{path}: must be one of {', '.join(kind)} (got {json.dumps(value)})")
    elif kind == "str":
        if not isinstance(value, str):
            errors.append(f"{path}: must be a string (got {json.dumps(value)})")
    elif kind == "bool":
        if not isinstance(value, bool):
            errors.append(f"{path}: must be true or false (got {json.dumps(value)})")
    elif kind == "str-list":
        if not isinstance(value, list) or not all(isinstance(i, str) for i in value):
            errors.append(f"{path}: must be a list of strings")
    elif kind == "tty-list":
        if not isinstance(value, list) or not all(isinstance(i, str) for i in value):
            errors.append(f"{path}: must be a list of strings")
            return
        for item in value:
            if not TTY.match(item):
                errors.append(f"{path}: '{item}' must be a /dev/ttyX device node")
    elif kind in PAIR_KEYS:
        a, b = PAIR_KEYS[kind]
        if not isinstance(value, list):
            errors.append(f"{path}: must be a list of {{ {a}, {b} }} objects")
            return
        for idx, item in enumerate(value):
            where = f"{path}[{idx}]"
            if not isinstance(item, dict):
                errors.append(f"{where}: must be a {{ {a}, {b} }} object")
                continue
            for req in (a, b):
                if not isinstance(item.get(req), str):
                    errors.append(f"{where}: missing string \"{req}\"")
            for extra in item:
                if is_comment(extra):
                    continue
                if extra not in (a, b):
                    errors.append(f"{where}: unknown key \"{extra}\"")
    else:
        raise AssertionError(f"unknown schema kind {kind!r}")


def validate(node, schema, prefix, errors):
    if not isinstance(node, dict):
        errors.append(f"{prefix or '(top level)'}: must be an object")
        return
    for key, value in node.items():
        if is_comment(key):
            continue
        path = f"{prefix}.{key}" if prefix else key
        if key not in schema:
            hint = RETIRED.get(path)
            errors.append(f"{path}: {hint}" if hint else f"{path}: unknown key")
            continue
        kind = schema[key]
        if isinstance(kind, dict):
            validate(value, kind, path, errors)
        else:
            check_leaf(path, kind, value, errors)


def descend(data, dotted):
    cur = data
    for part in dotted.split("."):
        if isinstance(cur, dict) and part in cur:
            cur = cur[part]
        else:
            return None, False
    return cur, True


def fmt_scalar(val):
    if isinstance(val, bool):
        return "true" if val else "false"
    return str(val)


def main(argv):
    if len(argv) < 2:
        sys.stderr.write(__doc__)
        return 3
    mode, path = argv[0], argv[1]

    if mode == "check":
        load(path)
        return 0
    if mode == "validate":
        errors = []
        validate(load(path), SCHEMA, "", errors)
        for err in errors:
            sys.stderr.write(f"error: {path}: {err}\n")
        return 4 if errors else 0

    if len(argv) < 3:
        sys.stderr.write("error: missing key\n")
        return 3
    data = load(path)
    value, found = descend(data, argv[2])

    if mode == "has":
        return 0 if found else 1
    if not found:
        return 1

    if mode == "get":
        if isinstance(value, (bool, str, int, float)):
            print(fmt_scalar(value))
            return 0
        return 1
    if mode == "list":
        if isinstance(value, list):
            for item in value:
                print(fmt_scalar(item))
            return 0
        return 1
    if mode == "rows":
        fields = argv[3:]
        if not isinstance(value, list) or not fields:
            return 1
        for item in value:
            if not isinstance(item, dict):
                continue
            print("\t".join(fmt_scalar(item.get(f, "")) for f in fields))
        return 0

    sys.stderr.write(f"error: unknown mode '{mode}'\n")
    return 3


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
