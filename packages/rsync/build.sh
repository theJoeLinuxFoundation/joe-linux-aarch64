build() {
    # Use wave 1's xxhash library for fast checksums. The manual pages ship
    # prebuilt in the tarball, so md2man (python-commonmark) is not needed.
    ./configure --prefix=/usr \
        --enable-xxhash \
        --without-included-zlib \
        --without-included-popt \
        --enable-openssl \
        --enable-zstd \
        --enable-lz4 \
        --enable-acl-support \
        --enable-xattr-support \
        --enable-idn \
        --disable-md2man
    make
}

package() {
    make DESTDIR="$DESTDIR" install

    # The book's install-rsyncd installs systemd units. Use upstream's
    # foreground command and restart policy in the optional dynamod service.
    # Rsync over ssh works without enabling the daemon.
    install -d "$DESTDIR/usr/lib/dynamod/services"
    cat > "$DESTDIR/usr/lib/dynamod/services/rsyncd.toml" <<'EOT'
[service]
name = "rsyncd"
exec = ["/usr/bin/rsync", "--daemon", "--no-detach"]
type = "simple"
enabled = false

[restart]
policy = "transient"
delay = "1s"

[dependencies]
after = ["loopback", "dhcpcd"]

[namespace]
enable = ["mnt"]
protect-system = "full"
bind-mounts = [{ source = "/etc", target = "/etc", writable = false }]

[readiness]
type = "none"
EOT

    # The account the book creates (groupadd -g 48, useradd -u 48).
    install -d "$DESTDIR/usr/lib/sysusers.d"
    cat > "$DESTDIR/usr/lib/sysusers.d/rsync.conf" <<'EOT'
g rsyncd 48
u rsyncd 48:48 "rsyncd Daemon" /home/rsync /usr/bin/false
EOT

    # The book's example configuration. /home/rsync is not created: /home is
    # shared between deployments and most machines never run the daemon, so
    # whoever enables it creates the directory or points the module elsewhere.
    install -d "$DESTDIR/etc"
    cat > "$DESTDIR/etc/rsyncd.conf" <<'EOT'
# This is a basic rsync configuration file
# It exports a single module without user authentication.

motd file = /home/rsync/welcome.msg
use chroot = yes

[localhost]
    path = /home/rsync
    comment = Default rsync module
    read only = yes
    list = yes
    uid = rsyncd
    gid = rsyncd

EOT
}
