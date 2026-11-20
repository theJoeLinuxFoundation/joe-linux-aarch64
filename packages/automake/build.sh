build() {
    ./configure --prefix=/usr --docdir=/usr/share/doc/automake-1.19
    make
}

package() {
    make DESTDIR="$DESTDIR" install
}
