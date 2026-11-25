//go:build linux

package main

import (
	"context"
	"net"
	"syscall"
)

// listen67 opens one UDP socket on 0.0.0.0:67 that receives both the clients'
// broadcasts and the server's unicast replies (sent to giaddr:67). The
// firewall must allow udp/67 only from the LAN interface and the server.
func listen67() (*net.UDPConn, error) {
	lc := net.ListenConfig{Control: func(_, _ string, c syscall.RawConn) error {
		var serr error
		if err := c.Control(func(fd uintptr) {
			if serr = syscall.SetsockoptInt(int(fd), syscall.SOL_SOCKET, syscall.SO_REUSEADDR, 1); serr != nil {
				return
			}
			serr = syscall.SetsockoptInt(int(fd), syscall.SOL_SOCKET, syscall.SO_BROADCAST, 1)
		}); err != nil {
			return err
		}
		return serr
	}}
	pc, err := lc.ListenPacket(context.Background(), "udp4", "0.0.0.0:67")
	if err != nil {
		return nil, err
	}
	return pc.(*net.UDPConn), nil
}

// lanSender opens a send-only socket bound to the LAN device, so the
// broadcast to clients leaves on that interface whatever the routing table
// says. It uses an ephemeral source port: reading is done on the :67 socket.
func lanSender(dev string) (*net.UDPConn, error) {
	lc := net.ListenConfig{Control: func(_, _ string, c syscall.RawConn) error {
		var serr error
		if err := c.Control(func(fd uintptr) {
			if serr = syscall.SetsockoptString(int(fd), syscall.SOL_SOCKET, syscall.SO_BINDTODEVICE, dev); serr != nil {
				return
			}
			serr = syscall.SetsockoptInt(int(fd), syscall.SOL_SOCKET, syscall.SO_BROADCAST, 1)
		}); err != nil {
			return err
		}
		return serr
	}}
	pc, err := lc.ListenPacket(context.Background(), "udp4", "0.0.0.0:0")
	if err != nil {
		return nil, err
	}
	return pc.(*net.UDPConn), nil
}
