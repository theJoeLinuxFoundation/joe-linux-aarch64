build() {
    # zlib-dynamic: libcrypto loads libz at run time when compression is used.
    ./config --prefix=/usr \
        --openssldir=/etc/ssl \
        --libdir=lib \
        shared \
        zlib-dynamic
    make
}

package() {
    # An empty INSTALL_LIBS keeps the static libraries out of the installation.
    make DESTDIR="$DESTDIR" INSTALL_LIBS= MANSUFFIX=ssl install
}
