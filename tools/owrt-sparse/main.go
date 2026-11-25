// owrt-sparse writes a disk image as a sparse file: all-zero blocks become
// holes. It can also grow the image to a larger size (the new tail is a hole).
// Output is written to OUT.tmp and renamed, so a failed run never leaves a
// half-written image behind.
//
//	owrt-sparse -in rootfs.img -out disk.img [-size 64M] [-block 4096]
package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
)

var version = "dev"

// parseSize accepts a byte count with an optional K, M or G suffix (powers of 1024).
func parseSize(s string) (int64, error) {
	s = strings.TrimSpace(strings.ToUpper(s))
	if s == "" {
		return 0, errors.New("empty size")
	}
	mult := int64(1)
	switch s[len(s)-1] {
	case 'K':
		mult = 1 << 10
	case 'M':
		mult = 1 << 20
	case 'G':
		mult = 1 << 30
	}
	if mult != 1 {
		s = s[:len(s)-1]
	}
	n, err := strconv.ParseInt(s, 10, 64)
	if err != nil || n < 0 {
		return 0, fmt.Errorf("bad size %q", s)
	}
	if n > (1<<62)/mult {
		return 0, errors.New("size too large")
	}
	return n * mult, nil
}

func allZero(b []byte) bool {
	for _, c := range b {
		if c != 0 {
			return false
		}
	}
	return true
}

// copySparse copies src to dst in block-sized steps and skips all-zero blocks.
// It returns the bytes read and the bytes left as holes.
func copySparse(dst io.WriterAt, src io.Reader, block int) (total, holes int64, err error) {
	if block <= 0 {
		return 0, 0, errors.New("block size must be > 0")
	}
	buf := make([]byte, block)
	for {
		n, rerr := io.ReadFull(src, buf)
		if n > 0 {
			if allZero(buf[:n]) {
				holes += int64(n)
			} else if _, werr := dst.WriteAt(buf[:n], total); werr != nil {
				return total, holes, werr
			}
			total += int64(n)
		}
		if rerr == io.EOF || rerr == io.ErrUnexpectedEOF {
			return total, holes, nil
		}
		if rerr != nil {
			return total, holes, rerr
		}
	}
}

// build copies in to out. size 0 keeps the input size; a smaller size than the
// input is refused, a larger one extends the image with a hole.
func build(in, out string, size int64, block int) (total, holes int64, err error) {
	src, err := os.Open(in)
	if err != nil {
		return 0, 0, err
	}
	defer src.Close()
	st, err := src.Stat()
	if err != nil {
		return 0, 0, err
	}
	if !st.Mode().IsRegular() {
		return 0, 0, fmt.Errorf("%s is not a regular file", in)
	}
	if size == 0 {
		size = st.Size()
	}
	if size < st.Size() {
		return 0, 0, fmt.Errorf("-size %d is smaller than the input (%d)", size, st.Size())
	}
	tmp := out + ".tmp"
	dst, err := os.OpenFile(tmp, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o644)
	if err != nil {
		return 0, 0, err
	}
	fail := func(e error) (int64, int64, error) {
		dst.Close()
		os.Remove(tmp)
		return 0, 0, e
	}
	if total, holes, err = copySparse(dst, src, block); err != nil {
		return fail(err)
	}
	if err = dst.Truncate(size); err != nil {
		return fail(err)
	}
	if err = dst.Sync(); err != nil {
		return fail(err)
	}
	if err = dst.Close(); err != nil {
		os.Remove(tmp)
		return 0, 0, err
	}
	if err = os.Rename(tmp, out); err != nil {
		os.Remove(tmp)
		return 0, 0, err
	}
	return total, holes, nil
}

func main() {
	in := flag.String("in", "", "input image")
	out := flag.String("out", "", "output image (sparse)")
	sizeS := flag.String("size", "0", "final size, e.g. 64M (0 = same as input)")
	block := flag.Int("block", 4096, "block size in bytes")
	showVersion := flag.Bool("version", false, "print version and exit")
	flag.Parse()
	if *showVersion {
		fmt.Println("owrt-sparse", version)
		return
	}
	if *in == "" || *out == "" {
		fmt.Fprintln(os.Stderr, "usage: owrt-sparse -in IMG -out IMG [-size N] [-block N]")
		os.Exit(2)
	}
	if *in == *out {
		fmt.Fprintln(os.Stderr, "owrt-sparse: -in and -out must differ")
		os.Exit(2)
	}
	size, err := parseSize(*sizeS)
	if err != nil {
		fmt.Fprintln(os.Stderr, "owrt-sparse:", err)
		os.Exit(2)
	}
	total, holes, err := build(*in, *out, size, *block)
	if err != nil {
		fmt.Fprintln(os.Stderr, "owrt-sparse:", err)
		os.Exit(1)
	}
	fmt.Printf("owrt-sparse: %d bytes read, %d bytes as holes -> %s\n", total, holes, *out)
}
