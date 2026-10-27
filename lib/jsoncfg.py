#!/usr/bin/env python3
"""Tiny JSON reader and schema validator for the agentdev launcher.

The sole config reader: lib/config.sh and lib/mounts.sh descend dotted keys into
the grouped agentdev-config.json with the verbs below.

Usage:
  jsoncfg.py get      <file> <dotted.key>   -> prints a scalar, exit 1 if missing/not scalar
  jsoncfg.py list     <file> <dotted.key>   -> prints list items, one per line (exit 1 if missing)
  jsoncfg.py table    <file> <dotted.key>   -> prints "key\tvalue" lines for an object of scalars
  jsoncfg.py check    <file>                -> exit 0 if file parses as JSON, else exit 3 + message
  jsoncfg.py validate <file>                -> exit 0 if file matches SCHEMA, else exit 4 + every error

Exit codes: 0 ok; 1 missing/wrong-type; 2 file not found; 3 parse error; 4 schema error.

Keys starting with "//" are comments and are ignored at every level.
"""
import json
import re
import sys

ENV_NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
URL = re.compile(r"^https?://[^/\s:]+(:[0-9]+)?(/\S*)?$")

# Leaf types: "str", "bool", "url", "env-list", "str-list", "str-map", or a tuple of
# allowed string values (an enum). A dict is a nested group.
SCHEMA = {
    "agent": {
        "name": ("claude",),
        "image": "str",
    },
    "model": {
        "id": "str",
        "provider": ("anthropic", "bedrock", "vertex"),
        "base_url": "url",
        "pass_env": "env-list",
    },
    "prompt": {
        "file": "str",
    },
    "profile": {
        "mode": ("clean", "remember", "profile"),
        "name": "str",
        "memory_store": "str",
        "keep": "bool",
        "profiles_root": "str",
        "clean_root": "str",
        "memory_root": "str",
    },
    "template": {
        "source": "str",
        "include": "str-list",
    },
    "auth": {
        "mode": ("auto", "api-key-env", "interactive", "inherit-credentials"),
    },
    "workspace": {
        "source": "str",
        "trust": ("skip-permissions", "workspace-only", "prompt"),
        "workdir": "str",
    },
    "network": {
        "mode": ("off", "allowlist", "none"),
        "allow": "str-list",
        "log": "bool",
        "mitm": "bool",
    },
    "mounts": {
        "workspace": ("rw", "ro"),
        "confirm_rw": "bool",
        "rw_allow": "str-list",
        "read_only": "str-map",
        "read_write": "str-map",
        "devices": "str-list",
    },
    "sandbox": {
        "ssh": "bool",
        "usb": "bool",
        "host_ca": "bool",
    },
}

# Keys from earlier config versions, so a stale file gets a pointed message.
RETIRED = {
    "profile.default_mode": "renamed to profile.mode",
    "workspace.isolation": "removed (only the bind-mounted workspace exists)",
    "template.strategy": "removed (only the copy strategy exists)",
}


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
        return
    if kind == "str":
        if not isinstance(value, str):
            errors.append(f"{path}: must be a string (got {json.dumps(value)})")
    elif kind == "bool":
        if not isinstance(value, bool):
            errors.append(f"{path}: must be true or false (got {json.dumps(value)})")
    elif kind == "url":
        if not isinstance(value, str) or not URL.match(value):
            errors.append(f"{path}: must be an http(s) URL with a host (got {json.dumps(value)})")
    elif kind in ("str-list", "env-list"):
        if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
            errors.append(f"{path}: must be a list of strings (got {json.dumps(value)})")
            return
        if kind == "env-list":
            for item in value:
                if not ENV_NAME.match(item):
                    errors.append(f"{path}: '{item}' is not a valid environment variable name")
    elif kind == "str-map":
        if not isinstance(value, dict) or not all(
                isinstance(v, str) for k, v in value.items() if not is_comment(k)):
            errors.append(f"{path}: must be an object of \"source\": \"destination\" strings")
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
            sys.exit(1)
    return cur


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
    value = descend(data, argv[2])

    if mode == "get":
        if isinstance(value, bool) or isinstance(value, (str, int, float)):
            print(fmt_scalar(value))
            return 0
        return 1
    if mode == "list":
        if isinstance(value, list):
            for item in value:
                print(fmt_scalar(item))
            return 0
        return 1
    if mode == "table":
        if isinstance(value, dict):
            for key, val in value.items():
                if is_comment(key):
                    continue
                if isinstance(val, bool) or isinstance(val, (str, int, float)):
                    print(f"{key}\t{fmt_scalar(val)}")
            return 0
        return 1

    sys.stderr.write(f"error: unknown mode '{mode}'\n")
    return 3


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
