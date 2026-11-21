build() {
    # Only libnghttp2: the applications (which are what would use libxml2,
    # OpenSSL, c-ares and so on) are not built.
    ./configure --prefix=/usr \
        --disable-static \
        --enable-lib-only \
        --docdir=/usr/share/doc/nghttp2-1.71.0
    make
}

package() {
    make DESTDIR="$DESTDIR" install
}
