# Following the book's parted page.
build() {
    ./configure --prefix=/usr \
        --disable-static \
        --enable-device-mapper \
        --with-readline
    make
}

package() {
    make DESTDIR="$DESTDIR" install
}
