prepare() {
    patch -Np1 -i "$SOURCES/coreutils-9.12-i18n-1.patch"
    # The patch changes the build system, so it has to be regenerated.
    autoreconf -fv
    automake -af
}

build() {
    # hostname: nothing else in joe Linux provides it. openssl is not shipped.
    FORCE_UNSAFE_CONFIGURE=1 ./configure \
        --prefix=/usr \
        --enable-install-program=hostname \
        --without-openssl
    make
}

package() {
    make DESTDIR="$DESTDIR" install

    install -d "$DESTDIR/usr/sbin" "$DESTDIR/usr/share/man/man8"
    mv "$DESTDIR/usr/bin/chroot" "$DESTDIR/usr/sbin"
    mv "$DESTDIR/usr/share/man/man1/chroot.1" "$DESTDIR/usr/share/man/man8/chroot.8"
    sed -i 's/"1"/"8"/' "$DESTDIR/usr/share/man/man8/chroot.8"
}
