# U-Boot boot script: A/B immutable-slot selection for pine-a64-gh-runner.
#
# Convention:
#   - Kernel assets (Image.<slot>, initramfs.<slot>, dtbs.<slot>/) live on the
#     BOOT vfat (p1) — same place ab-flash installs updated ones.
#   - Slot A root = /dev/mmcblk0p2, slot B root = /dev/mmcblk0p3
#   - Presence of file "boot_slot_b" on the BOOT vfat selects slot B;
#     absence selects slot A. Rollback = delete the file.
#   - If the chosen slot fails to yield a kernel, the other slot is tried once.
#   - @ROOT_OVERLAY_SIZE@ and @FDTFILE@ are substituted at build time.

setenv ovl_args "overlaytmpfs=yes overlaytmpfsflags=size=@ROOT_OVERLAY_SIZE@"
setenv common_args "@CMDLINE@ ${ovl_args}"

setenv active_slot a
setenv active_part 2

if load mmc 0:1 ${loadaddr} boot_slot_b; then
    setenv active_slot b
    setenv active_part 3
fi

echo "pine-a64-gh-runner: booting slot ${active_slot}"

setenv boot_slot "${active_slot}"
setenv boot_part "${active_part}"
setenv assets_ok 0

if load mmc 0:1 ${kernel_addr_r} Image.${boot_slot}; then
    if load mmc 0:1 ${fdt_addr_r} dtbs.${boot_slot}/allwinner/@FDTFILE@; then
        if load mmc 0:1 ${ramdisk_addr_r} initramfs.${boot_slot}; then
            setenv assets_ok 1
        fi
    fi
fi

if test "${assets_ok}" != "1"; then
    echo "slot ${boot_slot}: missing/broken assets, trying other slot"
    if test "${boot_slot}" = "a"; then
        setenv boot_slot b
        setenv boot_part 3
    else
        setenv boot_slot a
        setenv boot_part 2
    fi
    if load mmc 0:1 ${kernel_addr_r} Image.${boot_slot}; then
        if load mmc 0:1 ${fdt_addr_r} dtbs.${boot_slot}/allwinner/@FDTFILE@; then
            if load mmc 0:1 ${ramdisk_addr_r} initramfs.${boot_slot}; then
                setenv assets_ok 1
            fi
        fi
    fi
fi

if test "${assets_ok}" != "1"; then
    echo "FATAL: no bootable slot"
    sleep 10
    reset
fi

setenv bootargs "${common_args} root=/dev/mmcblk0p${boot_part}"
echo "cmdline: ${bootargs}"
booti ${kernel_addr_r} ${ramdisk_addr_r}:${filesize} ${fdt_addr_r}

echo "booti returned; rebooting"
sleep 5
reset
