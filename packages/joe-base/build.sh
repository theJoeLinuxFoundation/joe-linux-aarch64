# The console system's boot services (services/*.toml, for dynamod) and the
# two small programs they run. On joe Linux these were systemd's
# (systemd-remount-fs, local-fs.target, systemd-sysctl,
# systemd-modules-load, serial-getty@.service and its generator).

package() {
    local services="$DESTDIR/usr/lib/dynamod/services"
    install -d "$services"
    install -m644 /recipe/services/*.toml "$services/"

    install -d "$DESTDIR/usr/lib/joe"
    cat > "$DESTDIR/usr/lib/joe/serial-getty" <<'EOT'
#!/bin/sh
# Runs agetty on the serial console the kernel writes to: the last of
# /sys/class/tty/console/active that is not a virtual terminal (console= on
# the command line, or the firmware's console from ACPI SPCR). Without one
# there is nothing to do.
serial=
for c in $(cat /sys/class/tty/console/active 2>/dev/null); do
    case $c in
        tty[0-9]*) ;;
        *) serial=$c ;;
    esac
done
[ -n "$serial" ] || exit 0
# joe-test-console (test images only) and joe-live (the installation
# medium, which has no password to give) log root in.
if [ -e /usr/lib/joe/test-console ]; then
    exec /usr/sbin/agetty --autologin root --noclear --keep-baud 115200 "$serial" dumb
fi
if [ -e /usr/lib/joe/live-console ]; then
    exec /usr/sbin/agetty --autologin root --keep-baud 115200,57600,38400,9600 "$serial" vt220
fi
exec /usr/sbin/agetty --keep-baud 115200,57600,38400,9600 "$serial" vt220
EOT
    cat > "$DESTDIR/usr/lib/joe/modules-load" <<'EOT'
#!/bin/sh
# Loads the modules named in modules-load.d, as systemd-modules-load does:
# files from /etc, /run and /usr/lib, one with the same name in an earlier
# directory replacing a later one, read in the order of their names; empty
# lines and lines starting with # or ; are ignored.
seen=
for dir in /etc/modules-load.d /run/modules-load.d /usr/lib/modules-load.d; do
    for file in "$dir"/*.conf; do
        [ -e "$file" ] || continue
        name=${file##*/}
        case " $seen " in *" $name "*) continue ;; esac
        seen="$seen $name"
        printf '%s\n' "$name $file"
    done
done | sort | while read -r name file; do
    while read -r module _; do
        case $module in ''|'#'*|';'*) continue ;; esac
        /usr/sbin/modprobe -b "$module" || echo "modules-load: cannot load $module" >&2
    done < "$file"
done
exit 0
EOT
    cat > "$DESTDIR/usr/lib/joe/vt-getty" <<'EOT'
#!/bin/sh
# Runs agetty on a virtual terminal, logging root in on the installation
# medium (joe-live), which has no password to give.
autologin=
[ -e /usr/lib/joe/live-console ] && autologin="--autologin root"
exec /usr/sbin/agetty --noclear $autologin "$1" linux
EOT
    chmod 755 "$DESTDIR/usr/lib/joe/serial-getty" "$DESTDIR/usr/lib/joe/modules-load" \
        "$DESTDIR/usr/lib/joe/vt-getty"

    # Directories under the shared /var that programs expect to find.
    install -d "$DESTDIR/usr/lib/tmpfiles.d"
    cat > "$DESTDIR/usr/lib/tmpfiles.d/joe-base.conf" <<'EOT'
d /var/lib 0755 root root -
d /var/cache 0755 root root -
d /var/log 0755 root root -
d /var/log/dynamod 0755 root root -
d /var/spool 0755 root root -
d /var/spool/mail 1777 root root -
L /var/mail - - - - spool/mail
d /var/tmp 1777 root root 30d
L /var/run - - - - ../run
L /var/lock - - - - ../run/lock
EOT
}
