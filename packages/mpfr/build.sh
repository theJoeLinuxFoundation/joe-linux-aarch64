build() {
    ./configure --prefix=/usr \
        --disable-static \
        --enable-thread-safe \
        --docdir=/usr/share/doc/mpfr-4.2.2
    make
}

package() {
    make DESTDIR="$DESTDIR" install
}
