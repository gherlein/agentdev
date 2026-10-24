#!/usr/bin/env python3
"""Tiny JSON reader for the agentdev launcher.

The sole config reader: lib/config.sh and lib/mounts.sh descend dotted keys into
the grouped agentdev-config.json with the verbs below.

Usage:
  jsoncfg.py get   <file> <dotted.key>   -> prints a scalar, exit 1 if missing/not scalar
  jsoncfg.py list  <file> <dotted.key>   -> prints list items, one per line (exit 1 if missing)
  jsoncfg.py table <file> <dotted.key>   -> prints "key\tvalue" lines for an object of scalars
  jsoncfg.py check <file>                -> exit 0 if file parses as JSON, else exit 1 + message

Exit codes: 0 ok; 1 missing/wrong-type; 2 file not found; 3 parse error.
"""
import json
import sys


def load(path):
    try:
        with open(path, "rb") as fh:
            return json.load(fh)
    except FileNotFoundError:
        sys.exit(2)
    except (json.JSONDecodeError, ValueError) as exc:
        sys.stderr.write(f"error: {path}: invalid JSON: {exc}\n")
        sys.exit(3)


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
                if isinstance(val, bool) or isinstance(val, (str, int, float)):
                    print(f"{key}\t{fmt_scalar(val)}")
            return 0
        return 1

    sys.stderr.write(f"error: unknown mode '{mode}'\n")
    return 3


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
