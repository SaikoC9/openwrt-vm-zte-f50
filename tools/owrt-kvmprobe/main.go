// owrt-kvmprobe proves that KVM really works on this device: it opens
// /dev/kvm, checks the capabilities the OpenWrt VM needs, probes the
// in-kernel interrupt controller, then boots a tiny guest and checks that
// the guest code ran. Static binary, linux/arm64, no dependencies.
//
// Exit code 0 = PASS, 1 = FAIL.
package main

import (
	"flag"
	"fmt"
	"io"
	"os"
)

var version = "dev"

type report struct {
	w     io.Writer
	fails int
	warns int
}

func (r *report) ok(f string, a ...any)   { fmt.Fprintf(r.w, "[ OK ] "+f+"\n", a...) }
func (r *report) info(f string, a ...any) { fmt.Fprintf(r.w, "[INFO] "+f+"\n", a...) }
func (r *report) warn(f string, a ...any) { r.warns++; fmt.Fprintf(r.w, "[WARN] "+f+"\n", a...) }
func (r *report) fail(f string, a ...any) { r.fails++; fmt.Fprintf(r.w, "[FAIL] "+f+"\n", a...) }

func main() {
	showVersion := flag.Bool("version", false, "print version and exit")
	flag.Parse()
	if *showVersion {
		fmt.Println("owrt-kvmprobe", version)
		return
	}

	r := &report{w: os.Stdout}
	fmt.Fprintf(r.w, "=== owrt-kvmprobe %s ===\n", version)
	runProbe(r)
	fmt.Fprintln(r.w, "----------------------------------------")
	fmt.Fprintf(r.w, "FAIL: %d   WARN: %d\n", r.fails, r.warns)
	if r.fails == 0 {
		fmt.Fprintln(r.w, "RESULT: PASS - KVM runs guest code on this device")
		return
	}
	fmt.Fprintln(r.w, "RESULT: FAIL - VM route not usable, see FAIL lines above")
	os.Exit(1)
}
