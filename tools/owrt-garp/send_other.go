//go:build !linux

package main

import "errors"

func sendFrames(string, [][]byte, int, func()) error {
	return errors.New("owrt-garp runs only on Linux")
}
