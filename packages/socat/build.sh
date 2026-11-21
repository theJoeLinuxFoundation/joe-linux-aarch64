# Not in the book: the newest upstream release, built as its README says.
prepare() {
    patch -Np1 -i /recipe/openssl4.patch
}

build() {
    # OpenSSL (the OPENSSL address types) and readline (the READLINE address)
    # stated on; TCP wrappers are not packaged.
    ./configure --prefix=/usr \
        --sysconfdir=/etc \
        --enable-openssl \
        --enable-readline \
        --disable-libwrap
    make
}

package() {
    make DESTDIR="$DESTDIR" install
}
