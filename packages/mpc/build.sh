build() {
    ./configure --prefix=/usr \
        --disable-static \
        --docdir=/usr/share/doc/mpc-1.4.1
    make
}

package() {
    make DESTDIR="$DESTDIR" install
}
