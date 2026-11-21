# Not in the book: the newest upstream release, built as its INSTALL says.
build() {
    # The drive database shipped with the package is installed in
    # /usr/share/smartmontools for reference only; smartctl and smartd read
    # /var/lib/smartmontools/drivedb.h, which update-smart-drivedb writes
    # (a packaged copy would be sealed and could not be updated), and use
    # the copy compiled into them until it exists. The smartd service gets no
    # EnvironmentFile; options go in /etc/smartd.conf. No SELinux.
    ./configure --prefix=/usr \
        --sysconfdir=/etc \
        --localstatedir=/var \
        --with-drivedbinstdir=/usr/share/smartmontools \
        --with-drivedbdir=/var/lib/smartmontools \
        --with-update-smart-drivedb=yes \
        --with-gnupg=gpg \
        --with-scriptpath=/usr/bin \
        --with-initscriptdir=no \
        --with-savestates=no \
        --with-attributelog=no \
        --with-libcap-ng=yes \
        --with-libsystemd=no \
        --with-systemdsystemunitdir=no \
        --with-systemdenvfile=no \
        --with-selinux=no \
        --with-nvme-devicescan=yes
    make
}

package() {
    make DESTDIR="$DESTDIR" install

    # The optional smartd service runs in the foreground. The directory the drive
    # database is updated in (/var is not packaged).
    install -d "$DESTDIR/usr/lib/tmpfiles.d"
    cat > "$DESTDIR/usr/lib/tmpfiles.d/smartmontools.conf" << "EOF2"
d /var/lib/smartmontools 0755 root root -
EOF2

    install -d "$DESTDIR/usr/lib/dynamod/services"
    install -m644 /recipe/*.toml "$DESTDIR/usr/lib/dynamod/services/"
}
