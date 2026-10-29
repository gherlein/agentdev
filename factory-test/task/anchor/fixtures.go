// Package anchor holds the frozen acceptance suite for pngdec and the fixture
// builders it runs on. Fixtures are built in code so that any trial's binary can
// be scored without shipping blobs alongside it.
package anchor

import (
	"bytes"
	"encoding/binary"
	"hash/crc32"
	"image"
	"image/png"
)

// PNGSignature is the 8-byte PNG file header.
var PNGSignature = []byte{0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A}

// CRCOf computes the chunk CRC, which covers the type and data but not the
// declared length.
func CRCOf(typ string, data []byte) uint32 {
	h := crc32.NewIEEE()
	h.Write([]byte(typ))
	h.Write(data)
	return h.Sum32()
}

// Chunk builds a well-formed chunk with a correct declared length and CRC.
func Chunk(typ string, data []byte) []byte {
	return ChunkRaw(uint32(len(data)), typ, data, CRCOf(typ, data))
}

// ChunkRaw builds a chunk with every field set independently, so a fixture can
// declare one length while carrying a different payload, or carry a CRC that does
// not match its data.
func ChunkRaw(declaredLength uint32, typ string, data []byte, crc uint32) []byte {
	var b bytes.Buffer
	var scratch [4]byte
	binary.BigEndian.PutUint32(scratch[:], declaredLength)
	b.Write(scratch[:])
	b.WriteString(typ)
	b.Write(data)
	binary.BigEndian.PutUint32(scratch[:], crc)
	b.Write(scratch[:])
	return b.Bytes()
}

// IHDRData is the 13-byte header payload for a 1x1 8-bit grayscale image:
// width, height, bit depth, colour type, compression, filter, interlace.
func IHDRData() []byte {
	var b bytes.Buffer
	var scratch [4]byte
	binary.BigEndian.PutUint32(scratch[:], 1)
	b.Write(scratch[:])
	b.Write(scratch[:])
	b.Write([]byte{8, 0, 0, 0, 0})
	return b.Bytes()
}

// MinimalPNG is a genuinely valid 1x1 grayscale PNG. It is produced by the
// standard library's encoder rather than assembled by hand, so the baseline every
// other fixture mutates is known-good without trusting this file's own arithmetic.
func MinimalPNG() []byte {
	img := image.NewGray(image.Rect(0, 0, 1, 1))
	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		panic("encoding a 1x1 gray PNG cannot fail: " + err.Error())
	}
	return buf.Bytes()
}

// SplitChunks returns the chunks of a well-formed file, signature stripped, each
// slice covering length, type, data and CRC.
func SplitChunks(data []byte) [][]byte {
	var out [][]byte
	pos := len(PNGSignature)
	for pos+8 <= len(data) {
		length := int(binary.BigEndian.Uint32(data[pos : pos+4]))
		end := pos + 12 + length
		if end > len(data) {
			break
		}
		out = append(out, data[pos:end])
		pos = end
	}
	return out
}

// Rebuild prepends the signature to the given chunks.
func Rebuild(chunks ...[]byte) []byte {
	out := append([]byte{}, PNGSignature...)
	for _, c := range chunks {
		out = append(out, c...)
	}
	return out
}

// FindChunk returns the offset of the named chunk's length field and its declared
// length, or (-1, 0) if the type is absent.
func FindChunk(data []byte, typ string) (int, int) {
	pos := len(PNGSignature)
	for pos+8 <= len(data) {
		length := int(binary.BigEndian.Uint32(data[pos : pos+4]))
		if string(data[pos+4:pos+8]) == typ {
			return pos, length
		}
		pos += 12 + length
	}
	return -1, 0
}
