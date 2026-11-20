prepare() {
    # The distribution hook behind "trust extract-compat" and
    # update-ca-certificates: hand over to make-ca. make-ca is a run-time
    # companion only (it depends on p11-kit, not the other way round).
    sed '20,$ d' -i trust/trust-extract-compat
    cat >> trust/trust-extract-compat << "EOF"
# Copy existing anchor modifications to /etc/ssl/local
/usr/libexec/make-ca/copy-trust-modifications

# Update trust stores
/usr/sbin/make-ca -r
EOF
}

build() {
    mkdir p11-build
    cd p11-build
    # env_override_paths is not in the book: it makes libp11-kit honour the
    # P11_*_CONFIG_* environment variables (ignored in set-uid programs), which
    # is how the make-ca recipe points "trust extract" at the anchors staged in
    # its $DESTDIR instead of the build root's /etc/pki/anchors.
    # No systemd: the p11-kit-server socket unit has nowhere to go. There is
    # no bash-completion package.
    meson setup .. \
        --prefix=/usr \
        --buildtype=release \
        -D libdir=lib \
        -D trust_paths=/etc/pki/anchors \
        -D env_override_paths=enabled \
        -D systemd=disabled \
        -D bash_completion=disabled
    ninja
}

package() {
    cd p11-build
    DESTDIR="$DESTDIR" ninja install
    ln -sfv /usr/libexec/p11-kit/trust-extract-compat \
        "$DESTDIR/usr/bin/update-ca-certificates"

    # The trust module stands in for NSS's built-in root list, so that NSS
    # applications see the system trust store. The nss recipe leaves its own
    # libnssckbi.so out.
    ln -sfv ./pkcs11/p11-kit-trust.so "$DESTDIR/usr/lib/libnssckbi.so"
}
