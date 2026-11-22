# What turns the console system into the live system of the installation
# medium (image/live.zon). The medium's root is a compressed read-only image
# with a writable layer in memory over it, and nothing on it is kept, so:
#
# - root is logged in automatically on the consoles (joe-base's gettys look
#   for /usr/lib/joe/live-console): the medium has no password to give, as
#   other distributions' server media do not;
# - the medium is mounted where the installer reads it;
# - what only makes sense on an installed system is turned off: dave's
#   sealing (fs-verity is not available on the live root, and the installed
#   system seals itself), the upgrade applied at shutdown, and the boot check
#   and its watchdog (the medium is not a deployment);
# - the console says how to install.

package() {
    install -d "$DESTDIR/usr/lib/joe" "$DESTDIR/usr/lib/dynamod/services"
    echo 'The installation medium: root is logged in on the consoles.' > "$DESTDIR/usr/lib/joe/live-console"
    install -m644 /recipe/services/*.toml "$DESTDIR/usr/lib/dynamod/services/"

    cat > "$DESTDIR/usr/lib/joe/live-medium" <<'EOT'
#!/bin/sh
mkdir -p /run/live/medium
exec /usr/bin/mount -t iso9660 -o ro LABEL=JOE_LIVE /run/live/medium
EOT
    chmod 755 "$DESTDIR/usr/lib/joe/live-medium"

    # The administrator's switches, which on the medium are the medium's.
    install -d "$DESTDIR/etc/dynamod/disabled"
    local s
    for s in dave-seal dave-finalize dave-boot-check dave-boot-watchdog; do
        : > "$DESTDIR/etc/dynamod/disabled/$s"
    done

    cat > "$DESTDIR/etc/motd" <<'EOT'

This is joe Linux ARM's installation medium. Nothing done here is kept.

  dave install-system --list                  the disks, and what each allows
  dave install-system --disk /dev/nvme0n1     erase that disk and install

At its first start, the installed system asks on its console for root's
password, and offers an account of your own and an SSH key.

EOT
}
