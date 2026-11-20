build() {
    # The two makeinstall switches stop "make install" from running chown,
    # chgrp tty (wall, write) and chmod u+s itself; modes are set in package().
    ./configure --bindir=/usr/bin \
        --libdir=/usr/lib \
        --runstatedir=/run \
        --sbindir=/usr/sbin \
        --disable-chfn-chsh \
        --disable-login \
        --disable-nologin \
        --disable-su \
        --disable-setpriv \
        --disable-runuser \
        --disable-pylibmount \
        --disable-liblastlog2 \
        --disable-static \
        --without-python \
        --disable-makeinstall-chown \
        --disable-makeinstall-setuid \
        ADJTIME_PATH=/var/lib/hwclock/adjtime \
        --docdir=/usr/share/doc/util-linux-2.42.4
    make
}

package() {
    make DESTDIR="$DESTDIR" install

    chmod 4755 "$DESTDIR/usr/bin/mount" "$DESTDIR/usr/bin/umount"

    # /var is not packaged: the directory holding hwclock's adjtime file is
    # made at boot.
    install -d "$DESTDIR/usr/lib/tmpfiles.d"
    cat > "$DESTDIR/usr/lib/tmpfiles.d/joe-util-linux.conf" <<'EOT'
d /var/lib/hwclock 0755 root root -
EOT
}
