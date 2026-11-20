# Not in the book (Beyond LFS has dropped its page): the newest upstream
# release, built as its BUILDING.md says, with the switches and the
# privilege separation account of the book's last dhcpcd page.
build() {
    # Privilege separation as dhcpcd, seccomp filtering, the udev plugin
    # (dhcpcd waits for udev to finish naming an interface) and OpenSSL's
    # libcrypto for authentication. The kernel's packet filters are used,
    # not libpcap, as upstream recommends.
    #
    # Hooks: upstream's default ones (01-test, 20-resolv.conf, 30-hostname)
    # plus the one for NTP servers (chrony), named here because configure
    # would otherwise choose them by looking for the daemons in the build
    # root. There is no systemd-timesyncd.
    ./configure --prefix=/usr \
        --sysconfdir=/etc \
        --sbindir=/usr/sbin \
        --libexecdir=/usr/lib/dhcpcd \
        --dbdir=/var/lib/dhcpcd \
        --runstatedir=/run \
        --privsepuser=dhcpcd \
        --enable-privsep \
        --enable-seccomp \
        --with-udev \
        --with-openssl \
        --without-libpcap \
        --with-hooks=ntp.conf
    make
}

package() {
    make DESTDIR="$DESTDIR" install

    # The account and lease directory of the book (groupadd -g 52, useradd
    # -u 52; install -m700 -d /var/lib/dhcpcd, owned by dhcpcd).
    install -d "$DESTDIR/usr/lib/sysusers.d" "$DESTDIR/usr/lib/tmpfiles.d"
    cat > "$DESTDIR/usr/lib/sysusers.d/dhcpcd.conf" << "EOF"
g dhcpcd 52
u dhcpcd 52:52 "dhcpcd PrivSep" /var/lib/dhcpcd /usr/bin/false
EOF
    cat > "$DESTDIR/usr/lib/tmpfiles.d/dhcpcd.conf" << "EOF"
d /var/lib/dhcpcd 0700 dhcpcd dhcpcd -
EOF

    # Wired networking works without configuration: dhcpcd runs on every
    # interface from boot, in the foreground under the service manager.
    install -d "$DESTDIR/usr/lib/dynamod/services"
    cat > "$DESTDIR/usr/lib/dynamod/services/dhcpcd.toml" << "EOF"
[service]
name = "dhcpcd"
exec = ["/usr/sbin/dhcpcd", "-B", "-q"]
type = "simple"

[restart]
policy = "permanent"
delay = "2s"

[dependencies]
after = ["fstab-mount", "udev-coldplug", "loopback"]

[readiness]
type = "none"
EOF
}
