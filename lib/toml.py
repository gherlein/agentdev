#!/usr/bin/env python3
"""Tiny TOML reader for the agentdev launcher.

Usage:
  toml.py get   <file> <dotted.key>   -> prints a scalar, exit 1 if missing/not scalar
  toml.py list  <file> <dotted.key>   -> prints list items, one per line (exit 1 if missing)
  toml.py table <file> <dotted.key>   -> prints "key\tvalue" lines for a table of scalars
  toml.py check <file>                -> exit 0 if file parses as TOML, else exit 1 + message

Exit codes: 0 ok; 1 missing/wrong-type; 2 file not found; 3 parse error.
"""
import sys

try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover - Python < 3.11
    try:
        import tomli as tomllib  # type: ignore
    except ModuleNotFoundError:
        sys.stderr.write("error: need Python 3.11+ (tomllib) or the 'tomli' package\n")
        sys.exit(3)


def load(path):
    try:
        with open(path, "rb") as fh:
            return tomllib.load(fh)
    except FileNotFoundError:
        sys.exit(2)
    except tomllib.TOMLDecodeError as exc:
        sys.stderr.write(f"error: {path}: invalid TOML: {exc}\n")
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
        if isinstance(value, (str, int, float, bool)):
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
                if isinstance(val, (str, int, float, bool)):
                    print(f"{key}\t{fmt_scalar(val)}")
            return 0
        return 1

    sys.stderr.write(f"error: unknown mode '{mode}'\n")
    return 3


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
