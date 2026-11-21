build() {
    ./configure --prefix=/usr \
        --disable-static \
        --docdir=/usr/share/doc/libunistring-1.5
    make
}

package() {
    make DESTDIR="$DESTDIR" install
}
