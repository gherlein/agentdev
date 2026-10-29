You are a coding agent. The REPORT at the end of this prompt is one of two things:

- an audit gap report against `DESIGN.md`;
- the failing output of `make build && make test`.

Fix EXACTLY what the report shows, and nothing more.

For each reported gap or failure:

- implement the missing or corrected rule as `DESIGN.md` specifies it;
- add or strengthen a test that would FAIL a wrong implementation of that rule.

Then run `make build` and `make test`, and get both passing. Do not change code unrelated to the
report. Do not modify the spec documents (`VISION.md`, `REQUIREMENTS.md`, `DESIGN.md`).

## REPORT
