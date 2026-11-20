# systemd-udevd's standalone fork: joe Linux ARM has no systemd, and a server
# needs udev for the modules of its network and storage controllers (loaded
# when the hardware is found), for /dev/disk/by-* and for the rules packages
# ship in /usr/lib/udev/rules.d.
build() {
    ./configure --prefix=/usr \
        --sysconfdir=/etc \
        --bindir=/usr/bin \
        --sbindir=/usr/sbin \
        --libdir=/usr/lib \
        --with-rootprefix=/usr \
        --with-rootlibdir=/usr/lib \
        --with-rootrundir=/run \
        --enable-kmod \
        --enable-blkid \
        --enable-hwdb \
        --disable-selinux \
        --disable-manpages \
        --disable-static
    make
}

package() {
    make DESTDIR="$DESTDIR" install

    install -d "$DESTDIR/usr/lib/dynamod/services"
    cat > "$DESTDIR/usr/lib/dynamod/services/udev.toml" <<'EOT'
[service]
name = "udev"
supervisor = "early-boot"
exec = ["/usr/sbin/udevd"]
type = "simple"

[restart]
policy = "permanent"
delay = "1s"

[dependencies]
after = ["remount-root-rw"]

[readiness]
type = "none"
EOT
    # The devices that were there before udevd started: every subsystem and
    # device announced again, and the wait until udev has handled them all.
    cat > "$DESTDIR/usr/lib/dynamod/services/udev-coldplug.toml" <<'EOT'
[service]
name = "udev-coldplug"
supervisor = "early-boot"
exec = ["/bin/sh", "-c", "udevadm trigger --type=subsystems --action=add && udevadm trigger --type=devices --action=add && udevadm settle --timeout=60"]
type = "oneshot"

[restart]
policy = "temporary"

[dependencies]
requires = ["udev"]
after = ["modules-load"]

[readiness]
type = "none"
EOT

    # The hardware database is compiled from the files packages ship.
    install -d "$DESTDIR/usr/lib/dave/triggers"
    cat > "$DESTDIR/usr/lib/dave/triggers/13-hwdb.zon" <<'EOT'
.{
    .name = "hardware database",
    .paths = .{"usr/lib/udev/hwdb.d/"},
    .exec = .{ "/usr/bin/udevadm", "hwdb", "--update", "--usr" },
}
EOT
}
