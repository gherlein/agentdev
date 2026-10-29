"""Summarize `go test -json` output from the anchor suite into a score.

Usage: python3 -I anchor_score.py ANCHOR_JSON SCORE_JSON

A case is a leaf test: a top-level test with no subtests, or a subtest. Parent tests
(TestSpecs) are containers, not cases, so they are not counted. A case that never
reported pass/fail (the binary hung, or the package failed to build) counts as failed.
"""
import json
import sys

FINAL_ACTIONS = ("pass", "fail", "skip")


def leaf_results(events):
    results = {}
    for event in events:
        test = event.get("Test")
        if test and event.get("Action") in FINAL_ACTIONS:
            results[test] = event["Action"]
        elif test and test not in results and event.get("Action") == "run":
            results[test] = "unfinished"
    return {
        name: action for name, action in results.items()
        if not any(other.startswith(name + "/") for other in results)
    }


def main(anchor_path, score_path):
    with open(anchor_path) as handle:
        events = [json.loads(line) for line in handle if line.startswith("{")]
    leaves = leaf_results(events)
    passed = sorted(name for name, action in leaves.items() if action == "pass")
    failed = sorted(name for name, action in leaves.items() if action != "pass")
    build_failed = any(
        event.get("Action") == "fail" and not event.get("Test") for event in events
    ) and not leaves
    score = {
        "passed": len(passed),
        "total": len(leaves),
        "failed_cases": failed,
        "suite_build_failed": build_failed,
    }
    with open(score_path, "w") as handle:
        json.dump(score, handle, indent=2)
        handle.write("\n")
    print("anchor: %d/%d" % (score["passed"], score["total"]))


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: anchor_score.py ANCHOR_JSON SCORE_JSON")
    main(sys.argv[1], sys.argv[2])
