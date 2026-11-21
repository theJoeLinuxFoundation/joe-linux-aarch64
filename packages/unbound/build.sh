# Not in the book (Beyond LFS has dropped its page; blfs-systemd-units still
# carries the unit): the newest upstream release, built as its README says.
prepare() {
    # MSG_FASTOPEN belongs to sys/socket.h. The client probe includes only
    # netinet/tcp.h, which does not pull in the socket flags on bionic.
    sed -i '/ac_fn_check_decl .*"MSG_FASTOPEN"/a#include <sys/socket.h>' configure
}

build() {
    # The trust anchor is kept in /var/lib/unbound, which every deployment
    # shares and unbound may write to (RFC 5011 updates). Built with
    # libevent, DNS over HTTPS (nghttp2), EDNS client subnet, and TCP Fast Open. Dynamod
    # supervises the foreground process. Off: the Python module and bindings
    # (they need SWIG), DNSCrypt (libsodium), dnstap, the Redis cache
    # (hiredis) and the ipset module.
    ./configure --prefix=/usr \
        --sysconfdir=/etc \
        --localstatedir=/var \
        --disable-static \
        --with-conf-file=/etc/unbound/unbound.conf \
        --with-rootkey-file=/var/lib/unbound/root.key \
        --with-pidfile=/run/unbound.pid \
        --with-username=unbound \
        --with-ssl=/usr \
        --with-libexpat=/usr \
        --with-libevent=/usr \
        --with-libnghttp2=/usr \
        --disable-systemd \
        --enable-subnet \
        --enable-tfo-client \
        --enable-tfo-server \
        --without-pythonmodule \
        --without-pyunbound \
        --disable-dnscrypt \
        --disable-dnstap \
        --disable-cachedb \
        --disable-ipset
    make
}

package() {
    make DESTDIR="$DESTDIR" install

    # make install puts upstream's annotated example, every option commented
    # out, in place as the configuration. It is kept beside a short one that
    # turns on DNSSEC validation. The chroot (by default /etc/unbound) is
    # off because the trust anchor lives outside it.
    mv "$DESTDIR/etc/unbound/unbound.conf" "$DESTDIR/etc/unbound/unbound.conf.example"
    cat > "$DESTDIR/etc/unbound/unbound.conf" << "EOF"
# See unbound.conf(5). Every option, with its default, is described in
# /etc/unbound/unbound.conf.example.
server:
	# No chroot: the trust anchor below is outside /etc/unbound.
	chroot: ""
	# Validate DNSSEC. The root trust anchor is created and kept up to date
	# by the unbound-anchor service.
	auto-trust-anchor-file: "/var/lib/unbound/root.key"
EOF

    # The account unbound drops to after binding its sockets.
    install -d "$DESTDIR/usr/lib/sysusers.d"
    cat > "$DESTDIR/usr/lib/sysusers.d/unbound.conf" << "EOF"
g unbound 88
u unbound 88:88 "Unbound DNS Resolver" /var/lib/unbound /usr/bin/false
EOF

    # The anchor is updated as unbound, which must own its state directory.
    install -d "$DESTDIR/usr/lib/tmpfiles.d"
    echo 'd /var/lib/unbound 0755 unbound unbound -' > "$DESTDIR/usr/lib/tmpfiles.d/unbound.conf"

    install -d "$DESTDIR/usr/lib/dynamod/services"
    install -m644 /recipe/*.toml "$DESTDIR/usr/lib/dynamod/services/"
}
