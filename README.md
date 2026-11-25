# openwrt-vm-zte-f50

OpenWrt in a KVM virtual machine on the rooted ZTE F50 hotspot. Every
piece is built from source. Used by MatchiTOOL.

    scripts/owrt-build.sh        # build everything into dist/owrt/ + SHA256SUMS

MatchiTOOL plugin: `plugin/OpenWrt_VM_v1_0.js`. Release flow:

    scripts/owrt-release.sh --build dist/owrt --guest dist/guest --version 1.0.0   # writes the six release files
    # upload them to the GitHub release v1.0.0, paste the printed PIN_SUMS_SHA256 into the plugin

Tests: `bash scripts/test_owrt_vm.sh`, `bash scripts/test_owrt_install.sh`,
`node tests/test_plugin.js`, `node tests/test_plugin_ui.js` (needs Chromium).

## License

The code in this repository is MIT licensed (`LICENSE`). The release files built
from it contain other projects under their own licenses: OpenWrt and the Linux
kernel (GPL-2.0, among others) and cloud-hypervisor (Apache-2.0 / BSD-3-Clause).
