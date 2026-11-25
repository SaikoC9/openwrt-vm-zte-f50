//go:build !linux

package main

import "errors"

func session(*relay, string) error { return errors.New("owrt-ra6 runs on Linux only") }
