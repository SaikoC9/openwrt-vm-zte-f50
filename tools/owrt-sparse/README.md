# owrt-sparse

Writes a disk image as a sparse file (all-zero blocks become holes) and can grow it.
Output goes to `OUT.tmp` and is renamed when complete.

    owrt-sparse -in rootfs.img -out disk.img [-size 64M] [-block 4096]

`-size` smaller than the input is refused. Tests: `go test ./...`.
