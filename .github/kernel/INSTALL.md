# Raspberry Pi 5 kernel installation

Extract the archive and enter its top-level directory. On the Pi, install the
prebuilt modules with `sudo make modules_install` (requires GNU Make and kmod).
For a mounted target root filesystem, use
`sudo make modules_install INSTALL_MOD_PATH=/path/to/root`.
`make kernelrelease` prints the release used to name the module directory.

Back up the current boot files and copy the files under `boot/` to the firmware
partition (normally `/boot/firmware/` on Raspberry Pi OS). If your boot setup
uses an initramfs, generate one for the new release and configure the firmware to
load it before rebooting. Review any `kernel=` override in `config.txt`.

To reproduce the guide's runtime policy, preserve your existing boot arguments
and include these tokens on the single line in `cmdline.txt`.

```text
numa=fake=8 numa_policy=interleave iommu_dma_numa_policy=interleave system_heap.max_order=0 thp_anon=64K:always;2M:madvise
```

The kernel defaults transparent hugepage defragmentation to `defer`. After
boot, check the active policy with `cat /sys/kernel/mm/transparent_hugepage/defrag`.
