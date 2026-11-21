# Not in the book: the newest upstream release, built as its INSTALL.md says.
build() {
    # OpenSSL decrypts IPsec ESP; libcap-ng drops capabilities after the
    # capture is opened. No SNMP MIB names (libsmi), and the SMB printer that
    # upstream calls possibly buggy stays out.
    ./configure --prefix=/usr \
        --with-crypto \
        --with-cap-ng \
        --without-smi \
        --disable-smb
    make
}

package() {
    make DESTDIR="$DESTDIR" install
    # A second copy named after the version.
    rm "$DESTDIR/usr/bin/tcpdump.$PKG_VERSION"
}
