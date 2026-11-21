build() {
    # The trust store is the p11-kit trust module (anchors from make-ca).
    # Everything optional is stated so that the build root cannot change the
    # result: libidn2, zlib and zstd on; brotli, TPM and DANE (unbound) off.
    # --disable-doc --enable-manpages: the manual pages are installed, but the
    # Texinfo manual (not shipped anyway, and its regeneration needs
    # makeinfo) is left alone.
    ./configure --prefix=/usr \
        --docdir=/usr/share/doc/gnutls-3.8.13 \
        --disable-doc \
        --enable-manpages \
        --with-p11-kit \
        --with-default-trust-store-pkcs11="pkcs11:" \
        --with-idn \
        --with-zlib \
        --with-zstd \
        --without-brotli \
        --without-tpm2 \
        --without-tpm \
        --disable-libdane
    make
}

package() {
    make DESTDIR="$DESTDIR" install
}
