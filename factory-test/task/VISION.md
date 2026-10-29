# VISION — pngdec

> The north-star for the software-factory pipeline in this repo. `brainstorm` turns
> this into `REQUIREMENTS.md`, `designer` turns that into `DESIGN.md`, and the
> `implementer`/`fixer` build it — all inside `work/`. It is deliberately complete:
> the tool is scored by an external, frozen acceptance suite, so the design must
> capture every rule below.

## What we're building

`pngdec` — a Go command-line tool that reports the **chunk structure** of a PNG file
as JSON. It is a *structural* decoder: it parses the PNG container (the 8-byte
signature and the sequence of chunks). It does **not** decompress image data,
validate pixel formats, or render anything. A file whose chunk structure is intact
is well-formed for this tool even if the image it encodes is nonsense.

## Why

A small, exactly-specified tool whose correctness is entirely observable from the
outside (stdout JSON, stderr, exit code). It is the unit of work for exercising the
build → test → audit pipeline: precise enough that vague implementations fail, small
enough to finish in one pipeline run.

## Must do (goals)

- Read a PNG file (or stdin) and emit one compact JSON object describing its chunks.
- Distinguish **well-formed** from **malformed** files by an exact rule set (below).
- Emit **partial** results for malformed files — the chunks parsed before the failure.
- Use the exact JSON shape, key order, formats, and exit codes specified below.

## Must not do (non-goals)

- No image decoding, decompression (zlib/DEFLATE), pixel or color handling, rendering.
- No knowledge of chunk semantics beyond `IHDR` and `IEND` (any 4-ASCII-letter type
  is otherwise acceptable).
- No third-party dependencies; Go standard library only.

## Constraints

- **Language/platform:** Go, standard library only. Module name `pngdec`, a single
  `main` package, source in the working directory.
- **Deliverables:** the Go source, a test suite, and a `Makefile` with a `build`
  target that produces the binary at `./pngdec` and a `test` target that runs the
  suite. Both must succeed.
- Do not attempt to allocate a buffer for an absurd declared length (e.g.
  `0xFFFFFFFF`): detect that it exceeds the bytes remaining and report it instead.

## Invocation

    pngdec <file>    read the named file
    pngdec -         read the whole of standard input

Exactly one argument is required.

## PNG container format

An 8-byte signature `89 50 4E 47 0D 0A 1A 0A` (hex) followed by a sequence of chunks.
Each chunk is:

| Field  | Size    | Meaning |
|--------|---------|---------|
| length | 4 bytes | big-endian unsigned; size of `data`, NOT including type or CRC |
| type   | 4 bytes | four ASCII letters (`A`-`Z` or `a`-`z`) |
| data   | length  | payload (arbitrary bytes, may contain NUL) |
| crc    | 4 bytes | big-endian CRC-32 (IEEE, as `hash/crc32.ChecksumIEEE`) over `type` then `data`, NOT over `length` |

## Output contract

On every run that reaches the parser, write to stdout a single **compact** JSON
object (no spaces, no indentation, no embedded newlines) followed by one newline.
Keys in exactly this order, no others:

    {"valid":<bool>,"size":<int>,"signature_valid":<bool>,"chunks":[...],"errors":[...]}

- `valid` — true iff the file is well-formed (below).
- `size` — total number of input bytes read.
- `signature_valid` — true iff the first 8 bytes are the PNG signature.
- `chunks` — ordered array, file order, of every chunk parsed successfully. A chunk
  whose parse failed is **not** included. Never emit an empty array merely because
  the file is bad — include the chunks parsed before the failure.
- `errors` — ordered array of strings; empty iff `valid` is true. Each begins
  `offset <N>: ` where `<N>` is the decimal byte offset where the problem was
  detected; the rest is free-form.

Each `chunks` element, keys in exactly this order, no others:

    {"type":"<string>","offset":<int>,"length":<int>,"crc":"<string>","crc_valid":<bool>}

- `type` — the four type bytes as a string.
- `offset` — byte offset of the start of this chunk (its `length` field). The first
  chunk of a file with a valid signature is at offset 8.
- `length` — the declared length, as an integer.
- `crc` — the stored CRC as exactly 8 lowercase hex digits, zero-padded, no `0x`
  (e.g. `"a8a24f1b"`).
- `crc_valid` — true iff the stored CRC equals the CRC computed over `type` and `data`.

## Well-formed (all must hold)

1. The first 8 bytes are the PNG signature.
2. Every chunk parses completely: declared length does not exceed the bytes remaining
   after its type field, and its 4 CRC bytes are present.
3. Every chunk type is four ASCII letters.
4. Every chunk's stored CRC matches the computed CRC.
5. The first chunk is `IHDR` with declared length exactly 13.
6. The last chunk is `IEND` with declared length exactly 0.
7. There are no bytes after the `IEND` chunk's CRC.

Called out because they are easy to get wrong:

- A zero-length `IDAT` chunk is well-formed (0 is a legal declared length).
- Chunk data may contain NUL bytes anywhere (e.g. a `tEXt` chunk); `length` reports
  the full declared length regardless — data is bytes, never a NUL-terminated string.
- Multiple `IDAT` chunks are well-formed.
- An unrecognised 4-ASCII-letter chunk type is well-formed.
- A declared length of `0xFFFFFFFF` is malformed (exceeds bytes remaining): report and
  exit, do not allocate.

## Exit codes

| Code | When |
|------|------|
| 0 | The file is well-formed. |
| 2 | The file was read but is malformed. JSON still goes to stdout; a diagnostic naming the decimal byte offset of the first problem also goes to stderr. |
| 1 | Usage error (wrong number of arguments) or I/O error (missing file, a directory, unreadable). Nothing on stdout; a diagnostic on stderr. |

A zero-byte file is malformed, not an I/O error: exit 2, with `size` 0,
`signature_valid` false, an empty `chunks` array, and an error at offset 0.

## Test requirements (so any suite can run against any binary)

1. All fixtures constructed in code as byte slices — no `testdata/`, no reading
   fixture files from disk. Each test file self-contained.
2. Tests exercise the **built binary as a subprocess**. The binary path is the
   `PNGDEC_BIN` environment variable, defaulting to `./pngdec`.
3. Tests must not build the binary (no `go build`/`make` from tests); assume it
   exists at that path.
4. Tests must not import the `pngdec` package or call its functions — everything is
   observed through the subprocess: stdout, stderr, exit code.

## Acceptance

`make build` produces `./pngdec`; `make test` passes. Beyond the project's own tests,
the tool is scored by an external, frozen acceptance suite (`../anchor`, not present
in this workspace) that drives the binary through `PNGDEC_BIN` and checks the JSON,
exit codes, and every rule above — including each malformed-input rejection.
