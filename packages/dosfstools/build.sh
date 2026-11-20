build() {
    # --enable-compat-symlinks: dosfsck, dosfslabel, fsck.msdos, fsck.vfat,
    # mkdosfs, mkfs.msdos and mkfs.vfat as well as the fsck.fat, fatlabel and
    # mkfs.fat they point to. iconv is glibc's.
    ./configure --prefix=/usr \
        --enable-compat-symlinks \
        --mandir=/usr/share/man \
        --docdir=/usr/share/doc/dosfstools-4.2
    make
}

package() {
    make DESTDIR="$DESTDIR" install
}
