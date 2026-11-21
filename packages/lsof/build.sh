build() {
    ./configure --prefix=/usr --disable-static \
        --with-libtirpc \
        --without-selinux
    make
}

package() {
    make DESTDIR="$DESTDIR" install
}
