//go:build !linux

package main

import (
	"errors"
	"net"
)

func listen67() (*net.UDPConn, error) { return nil, errors.New("owrt-dhcprelay runs only on Linux") }
func lanSender(string) (*net.UDPConn, error) {
	return nil, errors.New("owrt-dhcprelay runs only on Linux")
}
