prepare() {
    # From the book: OpenSSL 4 has no SSLv3 method, but does not define the
    # macro that says so.
    local new_line='#if !defined OPENSSL_NO_SSL3_METHOD '
    new_line+='&& OPENSSL_VERSION_NUMBER < 0x40000000L'
    sed -i "/SSL3/c $new_line" src/openssl.c
}

build() {
    # The switches after --with-ssl state what the build root would otherwise
    # decide. No metalink (libmetalink, gpgme), c-ares or libproxy.
    ./configure --prefix=/usr \
        --sysconfdir=/etc \
        --with-ssl=openssl \
        --with-libpsl \
        --with-zlib \
        --with-libuuid \
        --enable-iri \
        --enable-pcre2 \
        --disable-pcre \
        --without-metalink \
        --without-cares \
        --disable-libproxy
    make
}

package() {
    make DESTDIR="$DESTDIR" install
}
