build() {
    # Keep the book's paths. dynamod runs the collector, so upstream's
    # installer must neither enable systemd units nor edit the host crontab.
    # lm-sensors and Performance Co-Pilot are unavailable.
    sa_lib_dir=/usr/lib/sa \
    sa_dir=/var/log/sa \
    conf_dir=/etc/sysstat \
    ./configure --prefix=/usr \
        --disable-file-attr \
        --disable-compress-manpg \
        --disable-sensors \
        --disable-pcp \
        --disable-automated-sar-reporting
    make
}

package() {
    make DESTDIR="$DESTDIR" install

    install -Dm755 /recipe/collect.sh "$DESTDIR/usr/lib/sa/collect"
    install -Dm644 /recipe/sysstat.toml "$DESTDIR/usr/lib/dynamod/services/sysstat.toml"

    # The daily data files (/var is not packaged).
    install -d "$DESTDIR/usr/lib/tmpfiles.d"
    cat > "$DESTDIR/usr/lib/tmpfiles.d/sysstat.conf" << "EOF"
d /var/log/sa 0755 root root -
EOF
}
