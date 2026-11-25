# owrt-dhcprelay

DHCPv4 relay (RFC 1542) for the routed and proxyarp tether modes. Client broadcasts
on the LAN device go to the server with giaddr = our LAN address; the server's reply
to giaddr:67 is broadcast to the clients on the LAN device. Needs root.

    owrt-dhcprelay -dev br0 -addr 192.168.88.2 -server 192.168.88.1

Android's DHCP server must be off. The firewall should allow udp/67 only from the LAN
device and the server. The reply to clients leaves from an ephemeral source port.
Tests: `go test ./...` cover the packet rules. The socket code has not run on a
device yet (Phase 5, step 7).
