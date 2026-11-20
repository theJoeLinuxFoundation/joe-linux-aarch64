build() {
    ./configure --prefix=/usr --disable-static --docdir=/usr/share/doc/xz-5.8.4
    make
}

package() {
    make DESTDIR="$DESTDIR" install
}
