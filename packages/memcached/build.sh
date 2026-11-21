# Not in the book: the newest upstream release, built as its README says.
build() {
    # TLS uses OpenSSL. The seccomp filters apply only when started with
    # "-o drop_privileges". Off: the experimental proxy (it builds a
    # bundled Lua) and regenerating the protocol specifications (xml2rfc);
    # the manual page ships ready-made.
    ./configure --prefix=/usr \
        --enable-tls \
        --enable-seccomp \
        --disable-sasl \
        --disable-proxy \
        --disable-docs \
        --disable-werror \
        --disable-dtrace
    make
}

package() {
    make DESTDIR="$DESTDIR" install

    # Upstream's helper for inspecting a running server, with its manual
    # page; make install leaves it out.
    install -Dm755 scripts/memcached-tool "$DESTDIR/usr/bin/memcached-tool"
    install -Dm644 scripts/memcached-tool.1 "$DESTDIR/usr/share/man/man1/memcached-tool.1"

    # Dynamod reads literal KEY=value lines. Keep the upstream cache,
    # connection and port settings in /etc/memcached.conf. With no SASL,
    # the packaged listener is local until an administrator changes OPTIONS.
    install -d "$DESTDIR/etc"
    cat > "$DESTDIR/etc/memcached.conf" <<'EOF'
PORT=11211
MAXCONN=1024
CACHESIZE=64
OPTIONS=-l 127.0.0.1,::1
EOF

    # The account dynamod uses for memcached. It keeps nothing on disk.
    install -d "$DESTDIR/usr/lib/sysusers.d"
    cat > "$DESTDIR/usr/lib/sysusers.d/memcached.conf" << "EOF"
g memcached 37
u memcached 37:37 "memcached daemon" - /usr/bin/false
EOF

    install -d "$DESTDIR/usr/lib/dynamod/services"
    install -m644 /recipe/*.toml "$DESTDIR/usr/lib/dynamod/services/"
}
