// Command pngdec-reference is our own implementation of spec/REQUIREMENTS.md. It
// exists only to prove the anchor suite scores a correct binary 25/25, and is
// never shown to a trial or copied into a trial tree.
package main

import (
	"encoding/binary"
	"encoding/json"
	"fmt"
	"hash/crc32"
	"io"
	"os"
)

var pngSignature = []byte{0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A}

const (
	exitOK         = 0
	exitUsageOrIO  = 1
	exitMalformed  = 2
	chunkOverhead  = 12
	headerOverhead = 8
)

// Field order in these structs is the JSON key order REQUIREMENTS.md pins, since
// encoding/json emits struct fields in declaration order.
type chunkReport struct {
	Type     string `json:"type"`
	Offset   int    `json:"offset"`
	Length   int    `json:"length"`
	CRC      string `json:"crc"`
	CRCValid bool   `json:"crc_valid"`
}

type fileReport struct {
	Valid          bool          `json:"valid"`
	Size           int           `json:"size"`
	SignatureValid bool          `json:"signature_valid"`
	Chunks         []chunkReport `json:"chunks"`
	Errors         []string      `json:"errors"`
}

func main() {
	args := os.Args[1:]
	if len(args) != 1 {
		fmt.Fprintln(os.Stderr, "usage: pngdec <file>|-")
		os.Exit(exitUsageOrIO)
	}

	data, err := readInput(args[0])
	if err != nil {
		fmt.Fprintf(os.Stderr, "pngdec: %v\n", err)
		os.Exit(exitUsageOrIO)
	}

	report := analyze(data)
	out, err := json.Marshal(report)
	if err != nil {
		fmt.Fprintf(os.Stderr, "pngdec: encoding report: %v\n", err)
		os.Exit(exitUsageOrIO)
	}
	os.Stdout.Write(append(out, '\n'))

	if !report.Valid {
		fmt.Fprintf(os.Stderr, "pngdec: %s\n", report.Errors[0])
		os.Exit(exitMalformed)
	}
	os.Exit(exitOK)
}

func readInput(arg string) ([]byte, error) {
	if arg == "-" {
		return io.ReadAll(os.Stdin)
	}
	return os.ReadFile(arg)
}

func analyze(data []byte) fileReport {
	report := fileReport{
		Size:   len(data),
		Chunks: []chunkReport{},
		Errors: []string{},
	}

	report.SignatureValid = len(data) >= len(pngSignature) &&
		string(data[:len(pngSignature)]) == string(pngSignature)
	if !report.SignatureValid {
		report.Errors = append(report.Errors, errAt(0, "missing or invalid PNG signature"))
		return report
	}

	pos := len(pngSignature)
	sawIEND := false
	for pos < len(data) {
		remaining := len(data) - pos
		if remaining < headerOverhead {
			report.Errors = append(report.Errors,
				errAt(pos, fmt.Sprintf("truncated chunk header: %d bytes remain, need 8", remaining)))
			break
		}

		// uint64 throughout, so a declared length of 0xFFFFFFFF compares correctly
		// instead of wrapping, and nothing is allocated from it.
		declared := uint64(binary.BigEndian.Uint32(data[pos : pos+4]))
		typ := string(data[pos+4 : pos+8])
		if declared+uint64(chunkOverhead) > uint64(remaining) {
			report.Errors = append(report.Errors,
				errAt(pos, fmt.Sprintf("chunk %q declares %d data bytes but only %d bytes remain",
					typ, declared, remaining-chunkOverhead)))
			break
		}
		length := int(declared)

		if !isChunkType(data[pos+4 : pos+8]) {
			report.Errors = append(report.Errors,
				errAt(pos+4, "chunk type is not four ASCII letters"))
			break
		}

		payload := data[pos+8 : pos+8+length]
		stored := binary.BigEndian.Uint32(data[pos+8+length : pos+chunkOverhead+length])
		computed := crc32.ChecksumIEEE(append([]byte(typ), payload...))
		crcValid := stored == computed

		report.Chunks = append(report.Chunks, chunkReport{
			Type:     typ,
			Offset:   pos,
			Length:   length,
			CRC:      fmt.Sprintf("%08x", stored),
			CRCValid: crcValid,
		})
		if !crcValid {
			report.Errors = append(report.Errors,
				errAt(pos, fmt.Sprintf("chunk %q stored CRC %08x does not match computed %08x",
					typ, stored, computed)))
		}

		index := len(report.Chunks) - 1
		if index == 0 && typ != "IHDR" {
			report.Errors = append(report.Errors,
				errAt(pos, fmt.Sprintf("first chunk is %q, want IHDR", typ)))
		}
		if index == 0 && typ == "IHDR" && length != 13 {
			report.Errors = append(report.Errors,
				errAt(pos, fmt.Sprintf("IHDR declares %d data bytes, want 13", length)))
		}
		if typ == "IEND" {
			if length != 0 {
				report.Errors = append(report.Errors,
					errAt(pos, fmt.Sprintf("IEND declares %d data bytes, want 0", length)))
			}
			sawIEND = true
			pos += chunkOverhead + length
			if pos < len(data) {
				report.Errors = append(report.Errors,
					errAt(pos, fmt.Sprintf("%d trailing bytes after IEND", len(data)-pos)))
			}
			break
		}
		pos += chunkOverhead + length
	}

	if !sawIEND {
		report.Errors = append(report.Errors, errAt(len(data), "no IEND chunk"))
	}

	report.Valid = len(report.Errors) == 0
	return report
}

func errAt(offset int, message string) string {
	return fmt.Sprintf("offset %d: %s", offset, message)
}

func isChunkType(b []byte) bool {
	if len(b) != 4 {
		return false
	}
	for _, c := range b {
		isUpper := c >= 'A' && c <= 'Z'
		isLower := c >= 'a' && c <= 'z'
		if !isUpper && !isLower {
			return false
		}
	}
	return true
}
