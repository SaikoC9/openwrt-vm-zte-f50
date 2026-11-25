package main

import (
	"bytes"
	"os"
	"path/filepath"
	"syscall"
	"testing"
)

func TestParseSize(t *testing.T) {
	for in, want := range map[string]int64{"0": 0, "512": 512, "4k": 4096, "48M": 48 << 20, "1G": 1 << 30} {
		got, err := parseSize(in)
		if err != nil || got != want {
			t.Errorf("parseSize(%q) = %d, %v; want %d", in, got, err, want)
		}
	}
	for _, in := range []string{"", "x", "-1", "M", "9999999999999G"} {
		if _, err := parseSize(in); err == nil {
			t.Errorf("parseSize(%q) should fail", in)
		}
	}
}

func makeInput(t *testing.T, dir string) (string, []byte) {
	// 64 KiB: data in block 0, zeros in blocks 1-9, data in block 10, partial last block.
	data := make([]byte, 16*4096-100)
	copy(data, bytes.Repeat([]byte{0xAA}, 4096))
	copy(data[10*4096:], bytes.Repeat([]byte{0xBB}, 4096))
	copy(data[len(data)-10:], bytes.Repeat([]byte{0xCC}, 10))
	p := filepath.Join(dir, "in.img")
	if err := os.WriteFile(p, data, 0o644); err != nil {
		t.Fatal(err)
	}
	return p, data
}

func TestBuildSameSize(t *testing.T) {
	dir := t.TempDir()
	in, data := makeInput(t, dir)
	out := filepath.Join(dir, "out.img")
	total, holes, err := build(in, out, 0, 4096)
	if err != nil {
		t.Fatal(err)
	}
	if total != int64(len(data)) {
		t.Errorf("total = %d, want %d", total, len(data))
	}
	if holes != 13*4096 { // blocks 1-9 and 11-14 are zero
		t.Errorf("holes = %d, want %d", holes, 13*4096)
	}
	got, _ := os.ReadFile(out)
	if !bytes.Equal(got, data) {
		t.Fatal("output differs from input")
	}
	if _, err := os.Stat(out + ".tmp"); !os.IsNotExist(err) {
		t.Error(".tmp file left behind")
	}
	var st syscall.Stat_t
	if err := syscall.Stat(out, &st); err == nil && st.Blocks*512 >= int64(len(data)) {
		t.Log("filesystem does not keep holes; skipping the block count check")
	}
}

func TestBuildGrow(t *testing.T) {
	dir := t.TempDir()
	in, data := makeInput(t, dir)
	out := filepath.Join(dir, "out.img")
	if _, _, err := build(in, out, 1<<20, 4096); err != nil {
		t.Fatal(err)
	}
	got, _ := os.ReadFile(out)
	if len(got) != 1<<20 || !bytes.Equal(got[:len(data)], data) || !allZero(got[len(data):]) {
		t.Fatal("grown image is wrong")
	}
}

func TestBuildErrors(t *testing.T) {
	dir := t.TempDir()
	in, _ := makeInput(t, dir)
	if _, _, err := build(in, filepath.Join(dir, "o"), 100, 4096); err == nil {
		t.Error("shrinking below the input size must fail")
	}
	if _, _, err := build(filepath.Join(dir, "missing"), filepath.Join(dir, "o"), 0, 4096); err == nil {
		t.Error("missing input must fail")
	}
	if _, _, err := build(dir, filepath.Join(dir, "o"), 0, 4096); err == nil {
		t.Error("a directory as input must fail")
	}
	if _, err := os.Stat(filepath.Join(dir, "o.tmp")); !os.IsNotExist(err) {
		t.Error("failed run left a .tmp file")
	}
}

func TestCopySparseBadBlock(t *testing.T) {
	if _, _, err := copySparse(nil, bytes.NewReader(nil), 0); err == nil {
		t.Error("block 0 must fail")
	}
}
