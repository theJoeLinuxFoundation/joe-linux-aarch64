build() {
    # The two makeinstall switches stop "make install" from running chown,
    # chgrp tty (wall, write) and chmod u+s itself; modes are set in package().
    # --without-udev: eudev, which depends on util-linux, is built after it,
    # and lsblk and findmnt would otherwise link libudev only when a rebuild
    # finds it installed.
    # No last and lslogins: they read login records, and bionic's utmp
    # functions read none (Android keeps no records; bionic writes them with
    # updwtmpx, for agetty, but cannot read them back).
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
        --without-udev \
        --disable-last \
        --disable-lslogins \
        --disable-makeinstall-chown \
        --disable-makeinstall-setuid \
        ADJTIME_PATH=/var/lib/hwclock/adjtime \
        --docdir=/usr/share/doc/util-linux-2.42.4
    make
}

package() {
    make DESTDIR="$DESTDIR" install
    # configure leaves agetty out without the C library's updwtmpx(), and
    # joe-base's console logins are agetty.
    [[ -e $DESTDIR/usr/sbin/agetty ]] || { echo "agetty was not built" >&2; return 1; }

    chmod 4755 "$DESTDIR/usr/bin/mount" "$DESTDIR/usr/bin/umount"

    # /var is not packaged: the directory holding hwclock's adjtime file is
    # made at boot.
    install -d "$DESTDIR/usr/lib/tmpfiles.d"
    cat > "$DESTDIR/usr/lib/tmpfiles.d/joe-util-linux.conf" <<'EOT'
d /var/lib/hwclock 0755 root root -
EOT
}
