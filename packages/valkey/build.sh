# Not in the book: the newest upstream release, built with its Makefile as
# its README describes.
#
# Valkey builds its own copies of what is in deps/ and links them
# statically: jemalloc (patched for active defragmentation, configured with
# a smaller quantum), Lua 5.1 (patched, with the cjson, cmsgpack, bit and
# struct libraries scripts rely on; the packaged Lua is 5.4 and cannot
# replace it), libvalkey (its C client, a hiredis fork) and linenoise.
# There are no manual pages in the source.

prepare() {
    patch -Np1 -i /recipe/openssl41.patch
    patch -Np1 -i /recipe/bionic-threads.patch
}

valkey_make() {
    # TLS built in rather than as a module, foreground supervision, and the
    # redis-* names for every program (upstream's default,
    # USE_REDIS_SYMLINKS) so that tools and scripts written for Redis keep
    # working. RDMA (rdma-core) is off, as it is by default.
    make CC="$CC" AR="$AR" RANLIB="$RANLIB" PREFIX=/usr BUILD_TLS=yes USE_SYSTEMD=no BUILD_RDMA=no \
        USE_REDIS_SYMLINKS=yes V=1 "$@"
}

build() {
    valkey_make
}

package() {
    # The Makefile installs to $(PREFIX)/bin and knows no DESTDIR. The same
    # options as for the build, or it builds again with different ones.
    valkey_make PREFIX="$DESTDIR/usr" install

    # Upstream's configuration files, with the server's data in
    # /var/lib/valkey (shared across deployments) and each pid file in its
    # service's runtime directory. The server listens on localhost only.
    # Sentinel retains the upstream settings for monitoring remote servers.
    install -d "$DESTDIR/etc/valkey"
    sed -e 's@^dir \./$@dir /var/lib/valkey@' \
        -e 's@^pidfile .*@pidfile /run/valkey/valkey.pid@' \
        -e 's@^# unixsocket /run/valkey.sock@# unixsocket /run/valkey/valkey.sock@' \
        valkey.conf > "$DESTDIR/etc/valkey/valkey.conf"
    sed -e 's@^pidfile .*@pidfile /run/valkey-sentinel/valkey-sentinel.pid@' \
        sentinel.conf > "$DESTDIR/etc/valkey/sentinel.conf"
    grep -q '^dir /var/lib/valkey$' "$DESTDIR/etc/valkey/valkey.conf"

    # The account both run as, its data directory, and the configuration
    # directory made writable by it: Sentinel rewrites its configuration
    # file as it learns about the servers it monitors (and refuses to start
    # when it cannot), and CONFIG REWRITE rewrites valkey.conf, each by
    # writing a new file beside the old one and renaming it.
    install -d "$DESTDIR/usr/lib/sysusers.d" "$DESTDIR/usr/lib/tmpfiles.d"
    cat > "$DESTDIR/usr/lib/sysusers.d/valkey.conf" << "EOF"
g valkey 38
u valkey 38:38 "Valkey server" /var/lib/valkey /usr/bin/false
EOF
    cat > "$DESTDIR/usr/lib/tmpfiles.d/valkey.conf" << "EOF"
d /var/lib/valkey 0750 valkey valkey -
d /run/valkey 0755 valkey valkey -
d /run/valkey-sentinel 0755 valkey valkey -
z /etc/valkey 0770 root valkey -
z /etc/valkey/valkey.conf 0640 root valkey -
z /etc/valkey/sentinel.conf 0660 root valkey -
EOF

    install -d "$DESTDIR/usr/lib/dynamod/services"
    install -m644 /recipe/*.toml "$DESTDIR/usr/lib/dynamod/services/"
}
