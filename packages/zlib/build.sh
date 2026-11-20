build() {
    ./configure --prefix=/usr
    make
}

package() {
    make DESTDIR="$DESTDIR" install
    rm -f "$DESTDIR/usr/lib/libz.a"
}
