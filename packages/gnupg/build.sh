prepare() {
    # joe's bionic has working ttyname and iconv. GnuPG's Android OS case
    # assumes a stub ttyname and UTF-8-only terminals.
    sed -i '/^    \*-linux-android\*)$/,/^        ;;$/d' configure
}

build() {
    mkdir build
    cd build
    # dirmngr needs GnuTLS or NTBTLS for keyservers and online certificate
    # checks. Neither is packaged. LDAP keyservers and X.509 directory
    # lookups also need OpenLDAP. scdaemon talks to CCID readers through
    # libusb, while tpm2d would need tpm2-tss.
    ../configure --prefix=/usr \
        --localstatedir=/var \
        --sysconfdir=/etc \
        --disable-gnutls \
        --disable-dirmngr \
        --disable-dirmngr-auto-start \
        --disable-wks-tools \
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
}
