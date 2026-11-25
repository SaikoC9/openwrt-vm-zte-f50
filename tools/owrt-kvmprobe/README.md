# owrt-kvmprobe

Proves that KVM runs guest code on the device. Opens `/dev/kvm`, checks the
capabilities the OpenWrt VM needs, probes in-kernel vGICv2/vGICv3, boots a
tiny aarch64 guest that prints `OK` and powers off through PSCI.
Static linux/arm64, no dependencies. Exit 0 = PASS, 1 = FAIL.

    owrt-kvmprobe            # run the probe
    owrt-kvmprobe -version

Build: `scripts/owrt-build.sh tools` (output in `dist/owrt/`).

Run on the F50 (as root):

    adb push owrt-kvmprobe /data/local/tmp/ && adb shell chmod 755 /data/local/tmp/owrt-kvmprobe
    su -c /data/local/tmp/owrt-kvmprobe

F50 result (Android 13, kernel 5.4.254): PASS, vGICv3 only.
`consts_test.go` checks the ioctl numbers, register ids and the guest program
on any host (`go test ./...`).
