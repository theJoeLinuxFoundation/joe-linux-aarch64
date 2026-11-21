# Not in the book: Debian's netcat-openbsd, built the way Debian builds it
# (debian/rules), and installed as nc.
prepare() {
    tar -xf "$SOURCES/netcat-openbsd_1.239-1.debian.tar.xz"
    local p
    while read -r p; do
        [[ -z $p || $p == \#* ]] && continue
        patch -Np1 -i "debian/patches/$p"
    done < debian/patches/series
}

build() {
    # The patched Makefile links libbsd (found with pkg-config) and
    # libresolv. DEBIAN_VERSION names the patch level in "nc -h".
    make CC="$CC" CFLAGS="-O2 -DDEBIAN_VERSION=\\\"1.239-1\\\""
}

package() {
    install -Dm755 nc "$DESTDIR/usr/bin/nc"
    install -Dm644 nc.1 "$DESTDIR/usr/share/man/man1/nc.1"
    # Also under its long name, as Debian (by alternatives) and Arch do.
    ln -s nc "$DESTDIR/usr/bin/netcat"
    ln -s nc.1 "$DESTDIR/usr/share/man/man1/netcat.1"
}
