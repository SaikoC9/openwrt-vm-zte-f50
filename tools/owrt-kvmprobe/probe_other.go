//go:build !(linux && arm64)

package main

import "runtime"

func runProbe(r *report) {
	r.fail("owrt-kvmprobe runs only on linux/arm64 (this build: %s/%s)", runtime.GOOS, runtime.GOARCH)
}
