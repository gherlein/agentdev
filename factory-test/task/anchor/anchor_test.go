package anchor

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"
)

// The binary under test is supplied rather than built, so that any trial's suite
// can be pointed at any trial's binary.
func binaryPath(t *testing.T) string {
	t.Helper()
	if p := os.Getenv("PNGDEC_BIN"); p != "" {
		return p
	}
	return "./pngdec"
}

type result struct {
	exitCode int
	stdout   []byte
	stderr   string
}

// A malformed length field must not send the binary off allocating gigabytes, so
// every invocation is bounded.
const runTimeout = 20 * time.Second

func run(t *testing.T, data []byte, viaStdin bool, extraArgs ...string) result {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), runTimeout)
	defer cancel()

	args := extraArgs
	var stdin io.Reader
	if extraArgs == nil {
		if viaStdin {
			args = []string{"-"}
			stdin = bytes.NewReader(data)
		} else {
			path := filepath.Join(t.TempDir(), "input.png")
			if err := os.WriteFile(path, data, 0o644); err != nil {
				t.Fatalf("writing fixture: %v", err)
			}
			args = []string{path}
		}
	}

	cmd := exec.CommandContext(ctx, binaryPath(t), args...)
	cmd.Stdin = stdin
	var out, errBuf bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &errBuf
	err := cmd.Run()

	if ctx.Err() != nil {
		t.Fatalf("binary did not exit within %s", runTimeout)
	}
	code := 0
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		code = exitErr.ExitCode()
	} else if err != nil {
		t.Fatalf("running binary: %v", err)
	}
	return result{exitCode: code, stdout: out.Bytes(), stderr: errBuf.String()}
}

type report struct {
	Valid          bool `json:"valid"`
	Size           int  `json:"size"`
	SignatureValid bool `json:"signature_valid"`
	Chunks         []struct {
		Type     string `json:"type"`
		Offset   int    `json:"offset"`
		Length   int    `json:"length"`
		CRC      string `json:"crc"`
		CRCValid bool   `json:"crc_valid"`
	} `json:"chunks"`
	Errors []string `json:"errors"`
}

func parse(t *testing.T, r result) report {
	t.Helper()
	var rep report
	if err := json.Unmarshal(r.stdout, &rep); err != nil {
		t.Fatalf("stdout is not the required JSON object: %v\nstdout: %q", err, r.stdout)
	}
	return rep
}

type wantChunk struct {
	typ      string
	offset   int
	length   int
	crcValid bool
}

type spec struct {
	name string
	data func() []byte
	// stdin routes the fixture through `pngdec -` instead of a temp file.
	stdin bool
	// args, when set, replaces the computed argv entirely, for the usage cases.
	args []string

	wantExit   int
	checkJSON  bool
	wantValid  bool
	wantSig    bool
	wantChunks []wantChunk
	// wantErrOffset is asserted against the first errors[] entry; -1 skips it,
	// because REQUIREMENTS.md pins the offset only where detection point is
	// unambiguous.
	wantErrOffset int
}

// Helpers that build the malformed variants out of a known-good baseline.

func chunksOf(data []byte) [][]byte { return SplitChunks(data) }

func withoutLast(chunks [][]byte) [][]byte { return chunks[:len(chunks)-1] }

func insertBefore(chunks [][]byte, index int, extra []byte) [][]byte {
	out := append([][]byte{}, chunks[:index]...)
	out = append(out, extra)
	return append(out, chunks[index:]...)
}

func corruptCRC(chunk []byte) []byte {
	out := append([]byte{}, chunk...)
	stored := binary.BigEndian.Uint32(out[len(out)-4:])
	binary.BigEndian.PutUint32(out[len(out)-4:], stored^0xFFFFFFFF)
	return out
}

var specs = []spec{
	{
		name: "ValidMinimalPNG", data: MinimalPNG,
		wantExit: 0, checkJSON: true, wantValid: true, wantSig: true,
		wantErrOffset: -1,
		wantChunks: []wantChunk{
			{typ: "IHDR", offset: 8, length: 13, crcValid: true},
		},
	},
	{
		name: "ValidViaStdin", data: MinimalPNG, stdin: true,
		wantExit: 0, checkJSON: true, wantValid: true, wantSig: true, wantErrOffset: -1,
	},
	{
		name: "ZeroByteFile", data: func() []byte { return []byte{} },
		wantExit: 2, checkJSON: true, wantValid: false, wantSig: false,
		wantChunks: []wantChunk{}, wantErrOffset: 0,
	},
	{
		name: "WrongMagicRightLength",
		data: func() []byte {
			return append([]byte("NOTAPNG!"), MinimalPNG()[8:]...)
		},
		wantExit: 2, checkJSON: true, wantValid: false, wantSig: false, wantErrOffset: 0,
	},
	{
		name: "TruncatedIHDR",
		data: func() []byte {
			return append(append([]byte{}, PNGSignature...), chunksOf(MinimalPNG())[0][:12]...)
		},
		wantExit: 2, checkJSON: true, wantValid: false, wantSig: true,
		wantChunks: []wantChunk{}, wantErrOffset: -1,
	},
	{
		name: "DeclaredLengthExceedsFile",
		data: func() []byte {
			return Rebuild(ChunkRaw(9999, "IHDR", IHDRData(), CRCOf("IHDR", IHDRData())))
		},
		wantExit: 2, checkJSON: true, wantValid: false, wantSig: true,
		wantChunks: []wantChunk{}, wantErrOffset: -1,
	},
	{
		name: "DeclaredLength32BitOverflow",
		data: func() []byte {
			return Rebuild(ChunkRaw(0xFFFFFFFF, "IHDR", IHDRData(), CRCOf("IHDR", IHDRData())))
		},
		wantExit: 2, checkJSON: true, wantValid: false, wantSig: true,
		wantChunks: []wantChunk{}, wantErrOffset: -1,
	},
	{
		name: "IncorrectStoredCRC",
		data: func() []byte {
			c := chunksOf(MinimalPNG())
			c[0] = corruptCRC(c[0])
			return Rebuild(c...)
		},
		wantExit: 2, checkJSON: true, wantValid: false, wantSig: true,
		wantChunks: []wantChunk{
			{typ: "IHDR", offset: 8, length: 13, crcValid: false},
		},
		wantErrOffset: -1,
	},
	{
		name:     "MissingIEND",
		data:     func() []byte { return Rebuild(withoutLast(chunksOf(MinimalPNG()))...) },
		wantExit: 2, checkJSON: true, wantValid: false, wantSig: true, wantErrOffset: -1,
	},
	{
		name:     "TrailingBytesAfterIEND",
		data:     func() []byte { return append(MinimalPNG(), []byte("junk")...) },
		wantExit: 2, checkJSON: true, wantValid: false, wantSig: true,
		wantErrOffset: len(MinimalPNG()),
	},
	{
		name: "ZeroLengthIDATIsValid",
		data: func() []byte {
			c := chunksOf(MinimalPNG())
			return Rebuild(insertBefore(c, 1, Chunk("IDAT", nil))...)
		},
		wantExit: 0, checkJSON: true, wantValid: true, wantSig: true, wantErrOffset: -1,
		wantChunks: []wantChunk{
			{typ: "IHDR", offset: 8, length: 13, crcValid: true},
			{typ: "IDAT", offset: 33, length: 0, crcValid: true},
		},
	},
	{
		name: "TextChunkWithEmbeddedNULsIsValid",
		data: func() []byte {
			c := chunksOf(MinimalPNG())
			text := Chunk("tEXt", []byte("Comment\x00hello\x00world"))
			return Rebuild(insertBefore(c, len(c)-1, text)...)
		},
		wantExit: 0, checkJSON: true, wantValid: true, wantSig: true, wantErrOffset: -1,
	},
	{
		name: "MultipleIDATIsValid",
		data: func() []byte {
			c := chunksOf(MinimalPNG())
			return Rebuild(insertBefore(c, 1, c[1])...)
		},
		wantExit: 0, checkJSON: true, wantValid: true, wantSig: true, wantErrOffset: -1,
	},
	{
		name: "UnknownAncillaryChunkIsValid",
		data: func() []byte {
			c := chunksOf(MinimalPNG())
			return Rebuild(insertBefore(c, len(c)-1, Chunk("qUdT", []byte{1, 2, 3}))...)
		},
		wantExit: 0, checkJSON: true, wantValid: true, wantSig: true, wantErrOffset: -1,
	},
	{
		name: "NonLetterChunkType",
		data: func() []byte {
			c := chunksOf(MinimalPNG())
			bad := ChunkRaw(3, string([]byte{0x00, 0x01, 0x02, 0x03}), []byte{1, 2, 3},
				CRCOf(string([]byte{0x00, 0x01, 0x02, 0x03}), []byte{1, 2, 3}))
			return Rebuild(insertBefore(c, len(c)-1, bad)...)
		},
		wantExit: 2, checkJSON: true, wantValid: false, wantSig: true, wantErrOffset: -1,
	},
	{
		name: "IHDRNotFirst",
		data: func() []byte {
			c := chunksOf(MinimalPNG())
			return Rebuild(insertBefore(c, 0, Chunk("gAMA", []byte{0, 1, 2, 3}))...)
		},
		wantExit: 2, checkJSON: true, wantValid: false, wantSig: true, wantErrOffset: -1,
	},
	{
		name: "IHDRWrongDeclaredLength",
		data: func() []byte {
			c := chunksOf(MinimalPNG())
			c[0] = Chunk("IHDR", IHDRData()[:12])
			return Rebuild(c...)
		},
		wantExit: 2, checkJSON: true, wantValid: false, wantSig: true, wantErrOffset: -1,
	},
	{
		name: "IENDWithNonZeroLength",
		data: func() []byte {
			c := chunksOf(MinimalPNG())
			c[len(c)-1] = Chunk("IEND", []byte{0})
			return Rebuild(c...)
		},
		wantExit: 2, checkJSON: true, wantValid: false, wantSig: true, wantErrOffset: -1,
	},
	{
		name: "ChunkOffsetsAreExact",
		data: func() []byte {
			c := chunksOf(MinimalPNG())
			return Rebuild(insertBefore(c, 1, Chunk("qUdT", []byte{1, 2, 3}))...)
		},
		wantExit: 0, checkJSON: true, wantValid: true, wantSig: true, wantErrOffset: -1,
		wantChunks: []wantChunk{
			{typ: "IHDR", offset: 8, length: 13, crcValid: true},
			{typ: "qUdT", offset: 33, length: 3, crcValid: true},
		},
	},
}

func TestSpecs(t *testing.T) {
	for _, s := range specs {
		t.Run(s.name, func(t *testing.T) {
			r := run(t, s.data(), s.stdin)
			if r.exitCode != s.wantExit {
				t.Errorf("exit code = %d, want %d\nstderr: %s", r.exitCode, s.wantExit, r.stderr)
			}
			if !s.checkJSON {
				return
			}
			rep := parse(t, r)
			if rep.Valid != s.wantValid {
				t.Errorf("valid = %v, want %v", rep.Valid, s.wantValid)
			}
			if rep.SignatureValid != s.wantSig {
				t.Errorf("signature_valid = %v, want %v", rep.SignatureValid, s.wantSig)
			}
			if got, want := rep.Size, len(s.data()); got != want {
				t.Errorf("size = %d, want %d", got, want)
			}
			if s.wantValid && len(rep.Errors) != 0 {
				t.Errorf("errors = %v, want empty for a well-formed file", rep.Errors)
			}
			if !s.wantValid && len(rep.Errors) == 0 {
				t.Error("errors is empty, want at least one entry for a malformed file")
			}
			if s.wantChunks != nil {
				if len(s.wantChunks) == 0 && len(rep.Chunks) != 0 {
					t.Errorf("chunks = %d entries, want 0", len(rep.Chunks))
				}
				for i, wc := range s.wantChunks {
					if i >= len(rep.Chunks) {
						t.Fatalf("chunks has %d entries, want at least %d", len(rep.Chunks), i+1)
					}
					gc := rep.Chunks[i]
					if gc.Type != wc.typ {
						t.Errorf("chunks[%d].type = %q, want %q", i, gc.Type, wc.typ)
					}
					if gc.Offset != wc.offset {
						t.Errorf("chunks[%d].offset = %d, want %d", i, gc.Offset, wc.offset)
					}
					if gc.Length != wc.length {
						t.Errorf("chunks[%d].length = %d, want %d", i, gc.Length, wc.length)
					}
					if gc.CRCValid != wc.crcValid {
						t.Errorf("chunks[%d].crc_valid = %v, want %v", i, gc.CRCValid, wc.crcValid)
					}
				}
			}
			if s.wantErrOffset >= 0 {
				want := "offset " + itoa(s.wantErrOffset) + ":"
				if len(rep.Errors) == 0 || !strings.HasPrefix(rep.Errors[0], want) {
					t.Errorf("errors[0] = %q, want prefix %q", rep.Errors, want)
				}
			}
			if s.wantExit == 2 && !strings.Contains(r.stderr, itoa(firstErrorOffset(rep))) {
				t.Errorf("stderr %q does not name the byte offset of the first problem", r.stderr)
			}
		})
	}
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var digits []byte
	for n > 0 {
		digits = append([]byte{byte('0' + n%10)}, digits...)
		n /= 10
	}
	return string(digits)
}

// firstErrorOffset pulls the offset back out of the reported message so stderr can
// be checked against whatever offset the implementation chose, for the cases where
// REQUIREMENTS.md leaves the detection point open.
func firstErrorOffset(rep report) int {
	if len(rep.Errors) == 0 {
		return -1
	}
	m := regexp.MustCompile(`^offset (\d+):`).FindStringSubmatch(rep.Errors[0])
	if m == nil {
		return -1
	}
	n := 0
	for _, c := range m[1] {
		n = n*10 + int(c-'0')
	}
	return n
}

func TestCRCIsEightLowercaseHexDigits(t *testing.T) {
	rep := parse(t, run(t, MinimalPNG(), false))
	re := regexp.MustCompile(`^[0-9a-f]{8}$`)
	for i, c := range rep.Chunks {
		if !re.MatchString(c.CRC) {
			t.Errorf("chunks[%d].crc = %q, want 8 lowercase hex digits", i, c.CRC)
		}
	}
	if len(rep.Chunks) == 0 {
		t.Fatal("no chunks reported for a valid PNG")
	}
	want := CRCOf("IHDR", IHDRData())
	if got := rep.Chunks[0].CRC; got != hex8(want) {
		t.Errorf("IHDR crc = %q, want %q", got, hex8(want))
	}
}

func hex8(v uint32) string {
	const digits = "0123456789abcdef"
	out := make([]byte, 8)
	for i := 7; i >= 0; i-- {
		out[i] = digits[v&0xF]
		v >>= 4
	}
	return string(out)
}

// REQUIREMENTS.md pins key order, so the check has to see the raw token stream
// rather than a map.
func TestJSONKeyOrder(t *testing.T) {
	r := run(t, MinimalPNG(), false)
	if got := topLevelKeys(t, r.stdout); !equalStrings(got, []string{"valid", "size", "signature_valid", "chunks", "errors"}) {
		t.Errorf("top-level keys = %v, want [valid size signature_valid chunks errors]", got)
	}
	if got := firstChunkKeys(t, r.stdout); !equalStrings(got, []string{"type", "offset", "length", "crc", "crc_valid"}) {
		t.Errorf("chunk keys = %v, want [type offset length crc crc_valid]", got)
	}
	if bytes.Contains(bytes.TrimRight(r.stdout, "\n"), []byte("\n")) {
		t.Error("output JSON contains a newline; REQUIREMENTS.md requires compact single-line JSON")
	}
}

// topLevelKeys walks the raw JSON token stream of an object (already positioned
// just past its opening '{') and returns the keys of its direct children, in
// order. It must not mistake a string-typed *value* (e.g. a chunk's "type" or
// "crc" field, both strings per REQUIREMENTS.md) for a key: the token stream
// alone doesn't tag key vs. value, so key/value position is tracked explicitly
// via expectKey, alternating with every token consumed at depth 0.
func topLevelKeys(t *testing.T, data []byte) []string {
	t.Helper()
	dec := json.NewDecoder(bytes.NewReader(data))
	expectDelim(t, dec, '{')
	var keys []string
	depth := 0
	expectKey := true
	for {
		tok, err := dec.Token()
		if err != nil {
			t.Fatalf("scanning JSON: %v", err)
		}
		if d, ok := tok.(json.Delim); ok {
			switch d {
			case '{', '[':
				depth++
			case '}', ']':
				if depth == 0 {
					return keys
				}
				depth--
				if depth == 0 {
					expectKey = true
				}
			}
			continue
		}
		if depth == 0 {
			if expectKey {
				if s, ok := tok.(string); ok {
					keys = append(keys, s)
				}
			}
			expectKey = !expectKey
		}
	}
}

func firstChunkKeys(t *testing.T, data []byte) []string {
	t.Helper()
	var raw struct {
		Chunks []json.RawMessage `json:"chunks"`
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		t.Fatalf("decoding chunks: %v", err)
	}
	if len(raw.Chunks) == 0 {
		t.Fatal("no chunks to check key order against")
	}
	return topLevelKeys(t, raw.Chunks[0])
}

func expectDelim(t *testing.T, dec *json.Decoder, want rune) {
	t.Helper()
	tok, err := dec.Token()
	if err != nil {
		t.Fatalf("reading JSON: %v", err)
	}
	if d, ok := tok.(json.Delim); !ok || rune(d) != want {
		t.Fatalf("first token = %v, want %c", tok, want)
	}
}

func equalStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func TestNoArgumentsIsUsageError(t *testing.T) {
	// runArgs rather than run: an empty extraArgs slice is indistinguishable from
	// none, so the argv has to be supplied exactly.
	r := runArgs(t, nil)
	if r.exitCode != 1 {
		t.Errorf("exit code = %d, want 1\nstderr: %s", r.exitCode, r.stderr)
	}
	if len(bytes.TrimSpace(r.stdout)) != 0 {
		t.Errorf("stdout = %q, want empty on a usage error", r.stdout)
	}
	if strings.TrimSpace(r.stderr) == "" {
		t.Error("stderr is empty, want a usage diagnostic")
	}
}

func TestTwoArgumentsIsUsageError(t *testing.T) {
	if r := runArgs(t, []string{"a.png", "b.png"}); r.exitCode != 1 {
		t.Errorf("exit code = %d, want 1", r.exitCode)
	}
}

func TestNonexistentFileIsIOError(t *testing.T) {
	path := filepath.Join(t.TempDir(), "absent.png")
	r := runArgs(t, []string{path})
	if r.exitCode != 1 {
		t.Errorf("exit code = %d, want 1\nstderr: %s", r.exitCode, r.stderr)
	}
	if len(bytes.TrimSpace(r.stdout)) != 0 {
		t.Errorf("stdout = %q, want empty on an I/O error", r.stdout)
	}
}

func TestDirectoryArgumentIsIOError(t *testing.T) {
	if r := runArgs(t, []string{t.TempDir()}); r.exitCode != 1 {
		t.Errorf("exit code = %d, want 1", r.exitCode)
	}
}

// runArgs invokes the binary with an exact argv and no stdin.
func runArgs(t *testing.T, args []string) result {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), runTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, binaryPath(t), args...)
	var out, errBuf bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &errBuf
	err := cmd.Run()
	if ctx.Err() != nil {
		t.Fatalf("binary did not exit within %s", runTimeout)
	}
	code := 0
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		code = exitErr.ExitCode()
	} else if err != nil {
		t.Fatalf("running binary: %v", err)
	}
	return result{exitCode: code, stdout: out.Bytes(), stderr: errBuf.String()}
}
