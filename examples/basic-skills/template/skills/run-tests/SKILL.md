---
name: run-tests
description: >-
  Use when the user wants to run the project's test suite and interpret the
  results — e.g. "run the tests", "is anything failing?", "check that my change
  didn't break anything". Covers finding the right test command for the project
  and reporting pass/fail with the relevant output.
---

# run-tests

Run the project's tests and report what passed, what failed, and why.

1. **Find the test command.** Look for the project's convention, in order:
   - a `Makefile` target (`make test`, `make check`),
   - `package.json` scripts (`npm test`, `pnpm test`),
   - `pytest` / `python -m pytest`, `go test ./...`, `cargo test`, etc.
   If several could apply, pick the one the project's README or CI uses.
2. **Run it** from the repository root. Capture stdout and stderr.
3. **Report** a one-line verdict (all passing / N failing) followed by the failing
   cases with their error messages. Do not paste the entire log — show the parts
   that explain a failure.
4. If nothing runs (no tests, missing deps), say so plainly rather than guessing.
