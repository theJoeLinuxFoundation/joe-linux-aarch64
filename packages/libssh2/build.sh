prepare() {
    patch -Np1 -i "$SOURCES/libssh2-1.11.1-security_fixes-1.patch"
}

build() {
    # OpenSSL and zlib are what the book's build finds; named here so that
    # libgcrypt in the build root is never chosen instead.
    ./configure --prefix=/usr \
        --with-crypto=openssl \
        --with-libz \
        --disable-docker-tests \
        --disable-examples-build \
        --disable-static
    make
}

package() {
    make DESTDIR="$DESTDIR" install
}
