prepare() {
    # Bionic's msgfmt cannot convert Latin-1. Keep those translations by
    # converting their text and charset declaration before building the catalogs.
    local po
    for po in nls/*.po; do
        if grep -q 'charset=ISO-8859-1' "$po"; then
            uconv -f ISO-8859-1 -t UTF-8 "$po" | sed 's/charset=ISO-8859-1/charset=UTF-8/' > "$po.utf8"
            mv "$po.utf8" "$po"
        fi
    done
}

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
