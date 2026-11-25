# owrt-garp

Gratuitous ARP (RFC 5227) for the guest MAC/IP, broadcast through an AF_PACKET socket. Needs root.

    owrt-garp -i br0 -mac 52:54:00:12:34:56 -ip 192.168.88.1 [-n 3] [-mode request|reply|both]

Tests: `go test ./...` (frame bytes, argument checks). Sending was checked on `lo` as root.
