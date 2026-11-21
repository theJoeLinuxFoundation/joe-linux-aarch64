build() {
    # Stated rather than left to detection: no texinfo for the manual, and
    # OpenSSL would only be used for comparison in the benchmark program.
    ./configure --prefix=/usr \
        --disable-static \
        --disable-documentation \
        --disable-openssl
    make
}

package() {
    make DESTDIR="$DESTDIR" install
    chmod -v 755 "$DESTDIR"/usr/lib/lib{hogweed,nettle}.so
}
