prepare() {
    # Joe has a working ttyname and supports the WKS tools. Keep the Android
    # configure exemption for iconv: bionic handles Unicode but not the EUC-JP
    # encoding required by the configure probe. GnuPG handles Latin-1 itself.
    sed -i '/^    \*-linux-android\*)$/,/^        ;;$/ {
        /have_android_system=yes/d
        /build_wks_tools=no/d
    }' configure
    # Without AM_ICONV's declaration probe, use bionic's char ** input.
    export CPPFLAGS="${CPPFLAGS:+$CPPFLAGS }-DICONV_CONST="
}

build() {
    mkdir build
    cd build
    # The book lists OpenLDAP as required, but configure only needs it for
    # LDAP keyservers and X.509 directory lookups in dirmngr; joe has no
    # OpenLDAP, so that is switched off. Keyservers over hkps and https use
    # GnuTLS (NTBTLS is not packaged). The smart card daemon talks to readers
    # directly through libusb. tpm2d would need tpm2-tss.
    ../configure --prefix=/usr \
        --localstatedir=/var \
        --sysconfdir=/etc \
        --enable-gnutls \
        --enable-dirmngr \
        --enable-dirmngr-auto-start \
        --with-default-trust-store-file=/etc/pki/tls/certs/ca-bundle.crt \
        --enable-sqlite \
        --enable-ccid-driver \
        --disable-ntbtls \
        --disable-ldap \
        --disable-tpm2d
    make
}

package() {
    cd build
    make DESTDIR="$DESTDIR" install
    test -x "$DESTDIR/usr/bin/dirmngr"
}
