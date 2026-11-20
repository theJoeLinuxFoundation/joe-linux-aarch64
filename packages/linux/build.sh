# Kernel modules and the kernel image must not be passed through strip.
NOSTRIP=1

# The kernel is built with LLVM's tools alone (clang, ld.lld, llvm-objcopy,
# llvm-strip and the rest): joe Linux ARM has no GCC and no binutils. ARCH
# is given although the build root is itself an aarch64 system, so that the
# build does not depend on the kernel guessing it from uname.
# The kernel's own build tools are compiled for the build root, against
# bionic, by hostcc, which keeps the kernel's internal headers from taking
# the place of the C library's (see there). bionic's ELF types are the
# kernel's (<linux/elf.h>: Elf64_Addr is unsigned long long), glibc's
# uint64_t (unsigned long): the same, but elf-parse.h passes one for the
# other, so that is not an error here.
kmake() {
    make ARCH=arm64 LLVM=1 HOSTCC=/recipe/hostcc \
        HOSTCFLAGS=-Wno-error=incompatible-pointer-types "$@"
}

prepare() {
    kmake mrproper
    # The joe security module lives in this recipe, not in a kernel fork.
    /recipe/joe-lsm/install.sh /recipe/joe-lsm
    kmake defconfig
    scripts/kconfig/merge_config.sh -m .config /recipe/joe.config
    kmake olddefconfig
    # Fail now, not at boot, if an option the boot path depends on was
    # dropped or became a module: without an initramfs a module cannot help
    # to find the root, and a console that appears only once the root is
    # mounted shows nothing of a boot that fails. In order: the kernel as a
    # compressed EFI application; the platform (ACPI and its serial console
    # table, MSIs, PCIe host bridges from ACPI or a device tree, the IOMMU);
    # the root's file system and the disks it may be on (NVMe, AHCI, SAS and
    # RAID adapters, virtio, Hyper-V); the EFI system partition and what
    # dynamod needs before it can load modules; the security module; the
    # serial consoles, early and late; the live medium, whose initramfs loads
    # no modules (a BMC's virtual media is USB); and switches that cannot be
    # modules (compressed firmware, the full netfilter, KVM).
    local opt
    for opt in EFI_STUB EFI_ZBOOT \
        ACPI ACPI_SPCR_TABLE ARM_GIC_V3_ITS ACPI_MCFG PCI_HOST_GENERIC ARM_SMMU_V3 \
        BTRFS_FS BTRFS_FS_POSIX_ACL BLK_DEV_NVME SATA_AHCI SCSI_MPT3SAS MEGARAID_SAS \
        VIRTIO_PCI VIRTIO_MMIO VIRTIO_BLK SCSI_VIRTIO HYPERV_VMBUS HYPERV_STORAGE \
        VFAT_FS EFIVAR_FS DEVTMPFS_MOUNT AUTOFS_FS \
        SECURITY_JOE SECURITY_NETWORK FS_VERITY CRYPTO_ECDSA \
        SERIAL_EARLYCON SERIAL_AMBA_PL011_CONSOLE SERIAL_8250_CONSOLE SERIAL_8250_PNP VIRTIO_CONSOLE \
        BLK_DEV_INITRD RD_ZSTD ISO9660_FS BLK_DEV_LOOP BLK_DEV_SR SQUASHFS SQUASHFS_XATTR SQUASHFS_XZ \
        XZ_DEC_ARM64 OVERLAY_FS USB_XHCI_HCD USB_STORAGE USB_UAS \
        FW_LOADER_COMPRESS_ZSTD NETFILTER_ADVANCED KVM; do
        grep -q "^CONFIG_$opt=y" .config || { echo "CONFIG_$opt is not built in" >&2; return 1; }
    done
    # Built in is not enough: a security module CONFIG_LSM leaves out is
    # never started.
    grep -q '^CONFIG_LSM=".*joe' .config || { echo "CONFIG_LSM does not start the joe module" >&2; return 1; }
    # Network adapters are modules: some need firmware from the root (ice's
    # package, tg3's on older chips), and the rest would only take memory on
    # every machine without them. Checked, with what containers, virtual
    # machines and VPNs need, so that a kernel update cannot drop them
    # silently.
    for opt in ENA_ETHERNET GVE MICROSOFT_MANA HYPERV_NET MLX5_CORE IXGBE I40E ICE IGB BNXT TIGON3 \
        THUNDER_NIC_PF HNS3 \
        WIREGUARD TUN NF_TABLES CIFS NFSD DM_CRYPT \
        VHOST_NET BRIDGE VETH IP_SET IP_VS NETFILTER_XT_NAT INET_ESP PPP; do
        grep -q "^CONFIG_$opt=m" .config || { echo "CONFIG_$opt is not a module" >&2; return 1; }
    done
}

build() {
    # Not the device trees defconfig would also build: UEFI firmware hands
    # the kernel its own, or ACPI tables, so none is shipped.
    kmake vmlinuz.efi modules
}

package() {
    local release
    release=$(kmake -s kernelrelease)
    kmake INSTALL_MOD_PATH="$DESTDIR/usr" INSTALL_MOD_STRIP=1 DEPMOD=/usr/sbin/depmod modules_install
    # dave looks for the kernel image here and copies it to the EFI system
    # partition when it creates a deployment; systemd-boot starts it as an
    # EFI application. vmlinuz.efi is one (EFI_ZBOOT, see joe.config): a PE
    # program that unpacks the kernel and enters its EFI stub. The plain
    # arch/arm64/boot/Image would boot the same way at almost three times
    # the size (49 MB against 18).
    install -Dm644 arch/arm64/boot/vmlinuz.efi "$DESTDIR/usr/lib/modules/$release/vmlinuz"
    install -Dm644 .config "$DESTDIR/usr/lib/modules/$release/config"
    rm -f "$DESTDIR/usr/lib/modules/$release"/{build,source}

    install -d "$DESTDIR/usr/lib/dave/triggers"
    cat > "$DESTDIR/usr/lib/dave/triggers/20-depmod.zon" <<EOT
.{
    .name = "kernel module dependencies",
    .paths = .{"usr/lib/modules/$release/"},
    .exec = .{ "/usr/sbin/depmod", "$release" },
}
EOT
}
