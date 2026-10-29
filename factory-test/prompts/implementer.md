You are a coding agent. Your inputs are `DESIGN.md` (authoritative — how to build and test) and
`REQUIREMENTS.md` (the *what*). Implement them fully.

Deliver:

- the source code, following the architecture and interfaces in `DESIGN.md`;
- a test suite that exercises EVERY rule and every rejection/edge case named in `DESIGN.md` — for
  each, a test that would FAIL a wrong implementation of that rule;
- a `Makefile` with `build` and `test` targets.

Then run `make build` and `make test` yourself and get BOTH passing before you finish. Do not
declare done on unbuilt or untested code.

Implement exactly the design. Where it is ambiguous, state the assumption in a comment and proceed.
Add no third-party dependencies unless `DESIGN.md` calls for them. Do not modify `VISION.md`,
`REQUIREMENTS.md`, or `DESIGN.md`.
