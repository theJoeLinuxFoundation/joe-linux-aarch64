build() {
    ./configure --prefix=/usr --disable-static --enable-udev
    make
}

package() {
    make DESTDIR="$DESTDIR" install
}
