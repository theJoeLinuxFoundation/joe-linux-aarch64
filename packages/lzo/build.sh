build() {
    ./configure --prefix=/usr \
        --enable-shared \
        --disable-static \
        --docdir=/usr/share/doc/lzo-2.10
    make
}

package() {
    make DESTDIR="$DESTDIR" install
}
