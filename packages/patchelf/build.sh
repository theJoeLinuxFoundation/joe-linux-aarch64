build() {
    ./configure --prefix=/usr \
        --docdir=/usr/share/doc/patchelf-0.19.3
    make
}

package() {
    make DESTDIR="$DESTDIR" install
}
