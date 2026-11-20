build() {
    mkdir -v build
    cd build
    # libblkid, libuuid, uuidd and the fsck wrapper come from util-linux.
    # fuse2fs (fuse3) and reading tar archives in mke2fs (libarchive) are
    # left out so the build root cannot switch them on; no cron exists.
    ../configure --prefix=/usr \
        --sysconfdir=/etc \
        --enable-elf-shlibs \
        --disable-libblkid \
        --disable-libuuid \
        --disable-uuidd \
        --disable-fsck \
        --disable-fuse2fs \
        --without-libarchive \
        --with-udev-rules-dir=/usr/lib/udev/rules.d \
        --with-systemd-unit-dir=no \
        --with-crond-dir=no
    make
}

package() {
    cd build
    make DESTDIR="$DESTDIR" install
    rm -fv "$DESTDIR"/usr/lib/{libcom_err,libe2p,libext2fs,libss}.a

    # metadata_csum_seed is not understood by GRUB.
    sed 's/metadata_csum_seed,//' -i "$DESTDIR/etc/mke2fs.conf"

    # e2scrub checks ext4 file systems on LVM snapshots. joe has no LVM, and
    # its timer would only run a script that cannot do anything.
    rm -f "$DESTDIR"/usr/lib/systemd/system/e2scrub* "$DESTDIR"/usr/sbin/e2scrub* \
        "$DESTDIR"/etc/e2scrub.conf "$DESTDIR"/usr/lib/udev/rules.d/*e2scrub* \
        "$DESTDIR"/usr/share/man/man8/e2scrub*
    rm -rf "$DESTDIR/usr/lib/e2fsprogs" "$DESTDIR/etc/cron.d"
}
