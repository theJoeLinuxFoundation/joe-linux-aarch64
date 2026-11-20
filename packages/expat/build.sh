build() {
    ./configure --prefix=/usr --disable-static --docdir=/usr/share/doc/expat-2.10.0
    make
}

package() {
    make DESTDIR="$DESTDIR" install
}
