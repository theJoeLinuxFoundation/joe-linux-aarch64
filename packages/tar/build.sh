prepare() {
    patch -Np1 -i "$SOURCES/tar-1.35-acl_fix-1.patch"
}

build() {
    FORCE_UNSAFE_CONFIGURE=1 ./configure --prefix=/usr
    make
}

package() {
    make DESTDIR="$DESTDIR" install
}
