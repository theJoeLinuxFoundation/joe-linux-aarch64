# Only the boot manager, from systemd's source. It is an EFI program that
# needs nothing of systemd (or of any C library) when it runs; joe Linux ARM
# has no systemd, so everything else meson could build is switched off
# (--auto-features=disabled and the boolean switches below), and only its one
# target is built. dave reads the version it states ("LoaderInfo") and
# copies it to the EFI system partition.
#
# clang's Android defaults pack relocations as RELR, which the ELF-to-PE
# converter (tools/elf2efi.py) does not read; the boot manager is linked
# without packing.

build() {
    meson setup build \
        --prefix=/usr \
        --buildtype=release \
        --auto-features=disabled \
        -D c_link_args=-Wl,--pack-dyn-relocs=none \
        -D mode=release \
        -D bootloader=enabled \
        -D efi=true \
        -D sbat-distro= \
        -D man=disabled \
        -D tests=false \
        -D install-tests=false \
        -D utmp=false \
        -D hibernate=false \
        -D ldconfig=false \
        -D resolve=false \
        -D firstboot=false \
        -D kernel-install=false \
        -D ukify=disabled
    ninja -C build src/boot/systemd-bootaa64.efi
}

package() {
    install -Dm644 build/src/boot/systemd-bootaa64.efi \
        "$DESTDIR/usr/lib/systemd/boot/efi/systemd-bootaa64.efi"
}
