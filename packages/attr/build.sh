build() {
    ./configure --prefix=/usr \
        --disable-static \
        --sysconfdir=/etc \
        --docdir=/usr/share/doc/attr-2.6.0
    make
}

package() {
    make DESTDIR="$DESTDIR" install
}
