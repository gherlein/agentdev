"""Print a Markdown table of every factory run under RUNS_DIR.

Usage: python3 -I results.py RUNS_DIR
"""
import json
import os
import sys


def load(path):
    try:
        with open(path) as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return None


def minutes(seconds):
    return "%.1f" % (seconds / 60.0) if isinstance(seconds, int) else "-"


def anchor_cell(score):
    if score is None:
        return "not scored"
    if score.get("no_binary"):
        return "no binary"
    return "%d/%d" % (score["passed"], score["total"])


def stage_minutes(meta, prefix):
    total = sum(step["seconds"] for step in meta.get("steps", []) if step["step"].startswith(prefix))
    return minutes(total)


def main(runs_dir):
    rows = []
    for name in sorted(os.listdir(runs_dir)):
        meta = load(os.path.join(runs_dir, name, "meta.json"))
        if meta is None:
            continue
        score = load(os.path.join(runs_dir, name, "score.json"))
        rows.append("| %s | %s | %s | %s | %s | %s | %s | %s |" % (
            name,
            meta.get("outcome", "running?"),
            minutes(meta.get("agent_seconds")),
            stage_minutes(meta, "implementer"),
            stage_minutes(meta, "fix-"),
            stage_minutes(meta, "audit-"),
            meta.get("audit_rounds", "-"),
            anchor_cell(score),
        ))
    print("| run | outcome | agent min | implement min | fix min | audit min | audits | anchor |")
    print("|---|---|---|---|---|---|---|---|")
    print("\n".join(rows) if rows else "| (no runs yet) | | | | | | | |")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: results.py RUNS_DIR")
    main(sys.argv[1])
