prepare() {
    # Let telnet use the terminal database of ncurses (LFS).
    sed -i 's/def HAVE_TERMCAP_TGETENT/ 1/' telnet/telnet.c
}

build() {
    # The book's switches leave out the servers and the clients that are
    # obsolete, insecure or better provided elsewhere (logger by util-linux,
    # whois, the r-commands). Added here:
    # - hostname is already shipped by coreutils in joe Linux;
    # - traceroute is the traceroute package's (the one most distributions
    #   ship, which also needs no set-uid for its default UDP probes);
    # - internationalised host names (libidn2 is in the build root),
    #   Kerberos, PAM and TCP wrappers are refused by name.
    ./configure --prefix=/usr \
        --bindir=/usr/bin \
        --localstatedir=/var \
        --disable-logger \
        --disable-whois \
        --disable-rcp \
        --disable-rexec \
        --disable-rlogin \
        --disable-rsh \
        --disable-servers \
        --disable-hostname \
        --disable-traceroute \
        --without-idn \
        --without-krb5 \
        --without-shishi \
        --without-pam \
        --without-wrap
    make
}

package() {
    make DESTDIR="$DESTDIR" install
    install -d "$DESTDIR/usr/sbin"
    mv -v "$DESTDIR/usr/bin/ifconfig" "$DESTDIR/usr/sbin/ifconfig"
}
