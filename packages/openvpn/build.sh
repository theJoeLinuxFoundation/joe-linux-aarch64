# Not in the book: the newest upstream release, built as its INSTALL says.
build() {
    # OpenSSL; LZO and LZ4 for peers that still compress; data channel
    # offload (DCO) through libnl; the auth-pam and down-root plugins;
    # foreground client and server services. No PKCS#11 tokens
    # (pkcs11-helper is not packaged) and no SELinux. The manual pages ship
    # ready-made.
    ./configure --prefix=/usr \
        --sysconfdir=/etc \
        --localstatedir=/var \
        --with-crypto-library=openssl \
        --enable-lzo \
        --enable-lz4 \
        --enable-dco \
        --enable-plugins \
        --enable-plugin-auth-pam \
        --enable-plugin-down-root \
        --enable-management \
        --disable-systemd \
        --disable-pkcs11 \
        --disable-selinux
    make
}

package() {
    make DESTDIR="$DESTDIR" install

    # Each optional service reads its configuration from a separate directory.
    install -dm755 "$DESTDIR/etc/openvpn/client" "$DESTDIR/etc/openvpn/server"
    install -d "$DESTDIR/usr/lib/tmpfiles.d"
    echo 'd /run/openvpn-server 0750 root root -' > "$DESTDIR/usr/lib/tmpfiles.d/openvpn.conf"

    install -d "$DESTDIR/usr/lib/dynamod/services"
    install -m644 /recipe/*.toml "$DESTDIR/usr/lib/dynamod/services/"
}
