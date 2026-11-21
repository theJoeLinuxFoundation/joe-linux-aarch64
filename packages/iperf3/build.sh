# Not in the book: the newest upstream release, built as its INSTALL says.
build() {
    # SCTP tests need lksctp-tools' netinet/sctp.h, which joe does not
    # package, so SCTP is switched off rather than left to detection.
    ./configure --prefix=/usr \
        --disable-static \
        --with-openssl=/usr \
        --without-sctp
    make
}

package() {
    make DESTDIR="$DESTDIR" install
    # The upstream service uses a dynamic user. nobody has no privileges
    # and the foreground server needs no persistent files.
    install -d "$DESTDIR/usr/lib/dynamod/services"
    install -m644 /recipe/*.toml "$DESTDIR/usr/lib/dynamod/services/"
}
