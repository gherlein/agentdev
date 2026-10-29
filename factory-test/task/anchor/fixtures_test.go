package anchor

import (
	"bytes"
	"encoding/binary"
	"hash/crc32"
	"image/png"
	"testing"
)

// The whole suite's credibility rests on MinimalPNG being a real PNG rather than
// something that merely looks like one, so it is checked with a decoder we did
// not write.
func TestMinimalPNGDecodes(t *testing.T) {
	img, err := png.Decode(bytes.NewReader(MinimalPNG()))
	if err != nil {
		t.Fatalf("MinimalPNG does not decode: %v", err)
	}
	if b := img.Bounds(); b.Dx() != 1 || b.Dy() != 1 {
		t.Fatalf("MinimalPNG bounds = %v, want 1x1", b)
	}
}

func TestMinimalPNGStructure(t *testing.T) {
	data := MinimalPNG()
	if !bytes.HasPrefix(data, PNGSignature) {
		t.Fatal("MinimalPNG lacks the PNG signature")
	}
	chunks := SplitChunks(data)
	if len(chunks) < 3 {
		t.Fatalf("SplitChunks returned %d chunks, want at least 3", len(chunks))
	}
	firstType := string(chunks[0][4:8])
	lastType := string(chunks[len(chunks)-1][4:8])
	if firstType != "IHDR" {
		t.Errorf("first chunk type = %q, want IHDR", firstType)
	}
	if lastType != "IEND" {
		t.Errorf("last chunk type = %q, want IEND", lastType)
	}
	if got := binary.BigEndian.Uint32(chunks[0][0:4]); got != 13 {
		t.Errorf("IHDR declared length = %d, want 13", got)
	}
}

func TestChunkLayoutAndCRC(t *testing.T) {
	payload := []byte("hello")
	got := Chunk("tEXt", payload)
	if len(got) != 4+4+len(payload)+4 {
		t.Fatalf("Chunk length = %d, want %d", len(got), 12+len(payload))
	}
	if n := binary.BigEndian.Uint32(got[0:4]); n != uint32(len(payload)) {
		t.Errorf("declared length = %d, want %d", n, len(payload))
	}
	if typ := string(got[4:8]); typ != "tEXt" {
		t.Errorf("type = %q, want tEXt", typ)
	}
	// The CRC covers type and data but not the length field. Recomputing it here
	// independently is the point of the test.
	want := crc32.ChecksumIEEE(append([]byte("tEXt"), payload...))
	if got := binary.BigEndian.Uint32(got[len(got)-4:]); got != want {
		t.Errorf("crc = %08x, want %08x", got, want)
	}
}

func TestChunkRawKeepsFieldsIndependent(t *testing.T) {
	got := ChunkRaw(0xFFFFFFFF, "IHDR", IHDRData(), 0xDEADBEEF)
	if n := binary.BigEndian.Uint32(got[0:4]); n != 0xFFFFFFFF {
		t.Errorf("declared length = %08x, want ffffffff", n)
	}
	if len(got) != 4+4+13+4 {
		t.Errorf("byte length = %d, want 25; ChunkRaw must not honour the declared length", len(got))
	}
	if c := binary.BigEndian.Uint32(got[len(got)-4:]); c != 0xDEADBEEF {
		t.Errorf("crc = %08x, want deadbeef", c)
	}
}

func TestIHDRDataIsThirteenBytes(t *testing.T) {
	if n := len(IHDRData()); n != 13 {
		t.Fatalf("IHDRData length = %d, want 13", n)
	}
}

func TestRebuildRoundTrips(t *testing.T) {
	original := MinimalPNG()
	if got := Rebuild(SplitChunks(original)...); !bytes.Equal(got, original) {
		t.Fatal("Rebuild(SplitChunks(x)) != x")
	}
}

func TestFindChunk(t *testing.T) {
	data := MinimalPNG()
	offset, length := FindChunk(data, "IHDR")
	if offset != 8 {
		t.Errorf("IHDR offset = %d, want 8", offset)
	}
	if length != 13 {
		t.Errorf("IHDR length = %d, want 13", length)
	}
	if offset, _ := FindChunk(data, "IEND"); offset != len(data)-12 {
		t.Errorf("IEND offset = %d, want %d", offset, len(data)-12)
	}
	if offset, _ := FindChunk(data, "zZzZ"); offset != -1 {
		t.Errorf("FindChunk for a missing type = %d, want -1", offset)
	}
}
