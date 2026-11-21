# Following the book's stunnel page. Not done here: "make cert", which would
# put a private key made on the build machine into the package; a site
# installs its own certificate as /etc/stunnel/stunnel.pem.
build() {
    # Stated besides the book's switches: systemd socket activation off, TCP
    # wrappers (not packaged) and the OpenSSL FIPS mode off.
    ./configure --prefix=/usr \
        --sysconfdir=/etc \
        --localstatedir=/var \
        --disable-systemd \
        --disable-libwrap \
        --disable-fips \
        --with-ssl=/usr \
        --with-bashcompdir=/usr/share/bash-completion/completions
    make
}

package() {
    make DESTDIR="$DESTDIR" install

    # The book's configuration: no service defined yet, the daemon in a
    # chroot in /var/lib/stunnel as the stunnel account.
    cat > "$DESTDIR/etc/stunnel/stunnel.conf" << "EOF2"
; File: /etc/stunnel/stunnel.conf

; Note: The pid and output locations are relative to the chroot location.

foreground = yes
pid    = /run/stunnel.pid
chroot = /var/lib/stunnel
client = no
setuid = stunnel
setgid = stunnel
cert   = /etc/stunnel/stunnel.pem

;debug = 7
;output = stunnel.log

;[https]
;accept  = 443
;connect = 80
;; "TIMEOUTclose = 0" is a workaround for a design flaw in Microsoft SSL
;; Microsoft implementations do not use SSL close-notify alert and thus
;; they are vulnerable to truncation attacks
;TIMEOUTclose = 0

EOF2

    # The book's account, and its chroot with the directory for the pid
    # file inside it.
    install -d "$DESTDIR/usr/lib/sysusers.d" "$DESTDIR/usr/lib/tmpfiles.d"
    cat > "$DESTDIR/usr/lib/sysusers.d/stunnel.conf" << "EOF2"
g stunnel 51
u stunnel 51:51 "stunnel Daemon" /var/lib/stunnel /usr/bin/false
EOF2
    cat > "$DESTDIR/usr/lib/tmpfiles.d/stunnel.conf" << "EOF2"
d /var/lib/stunnel 1770 stunnel stunnel -
d /var/lib/stunnel/run 0750 stunnel stunnel -
EOF2

    install -d "$DESTDIR/usr/lib/dynamod/services"
    install -m644 /recipe/*.toml "$DESTDIR/usr/lib/dynamod/services/"
}
