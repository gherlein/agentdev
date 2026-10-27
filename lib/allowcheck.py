#!/usr/bin/env python3
"""Decide whether an allowlist permits a host:port, using the egress proxy's rules.

Usage: allowcheck.py <image-dir> <host> <port> [rule ...]
Exit 0 if a CONNECT to host:port would be allowed, 1 if not.

The rules are parsed and matched by image/proxy.py itself, so this check and the
proxy's runtime enforcement cannot disagree.
"""
import sys


def main(argv):
    if len(argv) < 3:
        sys.stderr.write(__doc__)
        return 2
    image_dir, host, port = argv[0], argv[1], int(argv[2])
    # The image directory is the container build context; keep it free of caches.
    sys.dont_write_bytecode = True
    sys.path.insert(0, image_dir)
    import proxy  # noqa: E402 - located via image_dir at runtime

    rules = proxy.parse_rules("\n".join(argv[3:]))
    allowed, _ = proxy.decide(rules, host, port, None)
    return 0 if allowed else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
