build() {
    ./configure --prefix=/usr --sysconfdir=/etc
    make
}

package() {
    make DESTDIR="$DESTDIR" install
}
