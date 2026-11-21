build() {
    # brotli needs cmake to build. Keep it out so cmake can switch from
    # its bundled curl to this one without introducing a dependency cycle.
    # No HTTP/3 until ngtcp2 and nghttp3 are packaged.
    # The other switches after --with-ca-path state what the build root would
    # otherwise decide.
    ./configure --prefix=/usr \
        --disable-static \
        --with-openssl \
        --with-ca-path=/etc/ssl/certs \
        --with-zlib \
        --with-zstd \
        --with-libpsl \
        --with-nghttp2 \
        --without-ngtcp2 \
        --without-nghttp3 \
        --with-libidn2 \
        --without-brotli \
        --without-libssh2 \
        --without-libssh \
        --without-libgsasl \
        --without-gssapi \
        --disable-ldap \
        --disable-ldaps \
        --disable-ares
    make
}

package() {
    make DESTDIR="$DESTDIR" install
}
