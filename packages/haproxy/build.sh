# Not in the book: the newest upstream release, built as its INSTALL says
# for a recent Linux system with all options.
build() {
    # OpenSSL is new enough (3.5 or later) for QUIC (HTTP/3) with 0-RTT
    # through its own API, so USE_QUIC_OPENSSL_COMPAT is not needed. Also
    # on: Lua, PCRE2 with its JIT, and the Prometheus exporter. Compression
    # uses the bundled SLZ, upstream's default, rather than zlib. Systemd
    # notification is built in (Type=notify needs no library).
    make CC="$CC" TARGET=linux-musl \
        USE_OPENSSL=1 \
        USE_QUIC=1 \
        USE_LUA=1 \
        USE_PCRE2=1 \
        USE_PCRE2_JIT=1 \
        USE_PROMEX=1 \
        PREFIX=/usr
}

package() {
    make PREFIX=/usr DOCDIR=/usr/share/doc/haproxy DESTDIR="$DESTDIR" install

    # Upstream has no default configuration. This one only sets the
    # process-wide settings, after examples/basic-config-edge.cfg: chroot
    # into an empty directory, drop to the haproxy account, log to
    # stderr (collected by dynamod). Proxies are added here or in conf.d.
    install -d "$DESTDIR/etc/haproxy/conf.d"
    cat > "$DESTDIR/etc/haproxy/haproxy.cfg" << "EOT"
# See https://docs.haproxy.org/3.4/configuration.html. Files in
# /etc/haproxy/conf.d are read after this one.
global
	# Security hardening: isolate and drop privileges
	chroot /var/lib/haproxy
	user haproxy
	group haproxy

	# do not keep old processes longer than that after a reload
	hard-stop-after 5m

	# send logs to stderr for logging via the service manager
	log stderr local0 info

defaults
	mode http
	log global
	option httplog
	option dontlognull
	timeout connect 10s
	timeout client 1m
	timeout server 1m
EOT

    # The account haproxy drops to, and the empty directory it chroots
    # into.
    install -d "$DESTDIR/usr/lib/sysusers.d" "$DESTDIR/usr/lib/tmpfiles.d"
    cat > "$DESTDIR/usr/lib/sysusers.d/haproxy.conf" << "EOT"
g haproxy 45
u haproxy 45:45 "HAProxy load balancer" /var/lib/haproxy /usr/bin/false
EOT
    cat > "$DESTDIR/usr/lib/tmpfiles.d/haproxy.conf" << "EOT"
d /var/lib/haproxy 0755 root root -
EOT

    install -d "$DESTDIR/usr/lib/dynamod/services"
    install -m644 /recipe/*.toml "$DESTDIR/usr/lib/dynamod/services/"
}
