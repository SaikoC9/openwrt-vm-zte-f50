# host/

Static aarch64 binaries that run on the F50 (Rust, `aarch64-unknown-linux-musl`).

- `build.sh OUTDIR` runs every `host/<component>/build.sh OUTDIR`.
- `rust-toolchain.toml` pins rustc and the target.

## vmm/

Builds [cloud-hypervisor](https://github.com/cloud-hypervisor/cloud-hypervisor) (Apache-2.0) from the tag and commit in `vmm/vmm.pin`, static, `--features kvm`. Output: `OUTDIR/cloud-hypervisor`. Fails if the tag no longer points at the pinned commit.

Why not crosvm: plain cargo, static aarch64 musl release, boots a raw `Image`, virtio-pci, in-kernel GICv3 (the only GIC on this F50).

If linking fails in CI: `OWRT_VMM_LINKER=aarch64-linux-gnu-gcc`.

New component: add `host/<name>/build.sh OUTDIR`. `scripts/owrt-build.sh` rejects any ELF that is not static AArch64.
