# Not in the book: the newest upstream release, built as its INSTALL says.
build() {
    # chronyd drops root to the chrony account once it has the privileges
    # it keeps (libcap). NTS uses GnuTLS, other hashes Nettle; system call
    # filtering (chronyd -F) uses libseccomp. chronyc has no line editing:
    # chrony supports only libedit, which is not packaged. The manual pages
    # ship as .man.in files, so Asciidoctor is not needed.
    ./configure --prefix=/usr \
        --sysconfdir=/etc \
        --localstatedir=/var \
        --chronyrundir=/run/chrony \
        --with-pidfile=/run/chrony/chronyd.pid \
        --with-hwclockfile=/etc/adjtime \
        --with-user=chrony \
        --with-sendmail=/usr/sbin/sendmail \
        --enable-scfilter \
        --disable-readline \
        --without-editline \
        --without-nss \
        --without-tomcrypt
    make
}

package() {
    make DESTDIR="$DESTDIR" install

    # Upstream's example client configuration: the pool.ntp.org servers,
    # drift and NTS cookies kept in /var/lib/chrony.
    install -Dm644 examples/chrony.conf.example2 "$DESTDIR/etc/chrony.conf"

    # The account chronyd runs as, and the directories it writes to
    # (/var is not packaged). chronyd makes /run/chrony itself.
    install -d "$DESTDIR/usr/lib/sysusers.d" "$DESTDIR/usr/lib/tmpfiles.d"
    cat > "$DESTDIR/usr/lib/sysusers.d/chrony.conf" << "EOF"
g chrony 53
u chrony 53:53 "chrony daemon" /var/lib/chrony /usr/bin/false
EOF
    cat > "$DESTDIR/usr/lib/tmpfiles.d/chrony.conf" << "EOF"
d /var/lib/chrony 0750 chrony chrony -
d /var/log/chrony 0750 chrony chrony -
EOF

    install -d "$DESTDIR/usr/lib/dynamod/services"
    install -m644 /recipe/*.toml "$DESTDIR/usr/lib/dynamod/services/"
}
