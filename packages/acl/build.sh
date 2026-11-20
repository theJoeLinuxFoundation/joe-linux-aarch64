build() {
    ./configure --prefix=/usr \
        --disable-static \
        --docdir=/usr/share/doc/acl-2.4.0
    make
}

package() {
    make DESTDIR="$DESTDIR" install
}
