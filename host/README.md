# host/

Binaries that run on the F50 next to the VM. Rust, static aarch64
(`aarch64-unknown-linux-musl`).

- `build.sh OUTDIR` runs every `host/<component>/build.sh OUTDIR`.
- `rust-toolchain.toml` pins rustc and the target.
- `.cargo/config.toml` sets the target, `rust-lld` and `crt-static`.

## vmm/ - the VMM (cloud-hypervisor)

`vmm/build.sh OUTDIR` builds [cloud-hypervisor](https://github.com/cloud-hypervisor/cloud-hypervisor)
(Apache-2.0) from the tag and commit in `vmm/vmm.pin`, static, with `--features kvm`
(io_uring off). Output: `OUTDIR/cloud-hypervisor`. It exits with an error if the
tag no longer points at the pinned commit.

Why cloud-hypervisor and not crosvm: it is plain cargo with an official static
aarch64 musl release, it boots a raw arm64 `Image` directly, and it has
virtio-pci and an in-kernel GICv3 (the only GIC this F50 offers). crosvm needs
minijail and other C libraries.

If linking fails in CI, set `OWRT_VMM_LINKER=aarch64-linux-gnu-gcc`
(the workflow already installs `gcc-aarch64-linux-gnu`).

Boot test on the F50 (as root), no networking yet:

    cloud-hypervisor --seccomp false --kernel Image \
      --disk path=rootfs.img --cmdline "console=ttyS0 root=/dev/vda rw" \
      --cpus boot=2 --memory size=256M --serial tty --console off

`--seccomp false` is for the first boot only; turn the filter on again once the
guest runs. If there is no console output, try `console=ttyAMA0`.

Adding another component: `host/<name>/build.sh OUTDIR` builds from a pinned
source and copies its binaries into `OUTDIR`. `scripts/owrt-build.sh` then
rejects any ELF that is not AArch64 and static, and adds the file to `SHA256SUMS`.
