build() {
    ./configure --prefix=/usr \
        --disable-static \
        --docdir=/usr/share/doc/gettext-1.0
    make
}

package() {
    make DESTDIR="$DESTDIR" install
    chmod 0755 "$DESTDIR/usr/lib/preloadable_libintl.so"
}
