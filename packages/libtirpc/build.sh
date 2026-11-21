build() {
    # --disable-gssapi: MIT Kerberos is not part of joe Linux.
    ./configure --prefix=/usr \
        --sysconfdir=/etc \
        --disable-static \
        --disable-gssapi
    make
}

package() {
    make DESTDIR="$DESTDIR" install
}
