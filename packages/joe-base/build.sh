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
# An installed system's first start: nobody can log in yet (first-setup).
if /usr/lib/joe/needs-first-setup; then
    exec /usr/sbin/agetty --autologin root --login-program /usr/lib/joe/first-setup \
        --keep-baud 115200,57600,38400,9600 "$serial" vt220
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
# medium (joe-live), which has no password to give, and running first-setup
# on an installed system's first start, when nobody can log in yet.
if [ -e /usr/lib/joe/live-console ]; then
    exec /usr/sbin/agetty --noclear --autologin root "$1" linux
fi
if /usr/lib/joe/needs-first-setup; then
    exec /usr/sbin/agetty --noclear --autologin root --login-program /usr/lib/joe/first-setup "$1" linux
fi
exec /usr/sbin/agetty --noclear "$1" linux
EOT
    # An installed system has no account anyone can log in with: root's
    # password is locked (joe-filesystem) and there is no other account.
    # Until one exists, the consoles run first-setup instead of login. The
    # test is the system's state, not a marker, so a system someone has
    # provisioned another way (an image with accounts, a key for root) never
    # sees it, and one whose accounts are all locked again sees it again.
    cat > "$DESTDIR/usr/lib/joe/needs-first-setup" <<'EOT'
#!/bin/sh
# Exits 0 when nobody could log in: no account in /etc/shadow has a usable
# password (an empty one does not count) and root has no SSH key.
[ -e /usr/lib/joe/live-console ] && exit 1
[ -e /usr/lib/joe/test-console ] && exit 1
[ -s /root/.ssh/authorized_keys ] && exit 1
awk -F: '$2 != "" && $2 !~ /^[!*]/ { usable = 1 } END { exit usable ? 1 : 0 }' /etc/shadow
EOT
    cat > "$DESTDIR/usr/lib/joe/first-setup" <<'EOT'
#!/bin/sh
# The first start of an installed system, on whichever console someone
# reaches first (agetty runs this in place of login, as root). It sets root's
# password, then offers an administrator account (in wheel, which doas lets
# act as root) and an SSH public key, and returns; the console's getty then
# starts again and shows the ordinary login prompt. Interrupting it, or
# ending its input, returns too, and the setup starts again if nobody can
# log in yet.
PATH=/usr/bin:/usr/sbin
trap 'exit 1' INT QUIT TERM
trap '' TSTP

# Every console runs this until someone finishes it on one of them. None
# waits for another: a server may have nobody at its screen, only at its
# serial console. The one that finishes ends the others (below), whose
# gettys then start again and find the setup done.
/usr/lib/joe/needs-first-setup || exit 0

cat <<'TXT'

Welcome to joe Linux ARM. This is the system's first start, and nobody can
log in to it yet. Choose a password for root, the administrator.

TXT
until passwd root; do echo "That did not work; try again."; done

cat <<'TXT'

You can also create an account of your own, which becomes root with doas.
Logging in to it over SSH is then possible with its password; root logs in
over SSH only with a key.

TXT
user=
while :; do
    printf 'Account name (empty for none): '
    read -r user || exit 0
    [ -z "$user" ] && break
    if ! printf '%s\n' "$user" | grep -qE '^[a-z_][a-z0-9_-]{0,31}$'; then
        echo "A name is lower-case letters, digits, - and _, and starts with a letter or _."
    elif getent passwd "$user" >/dev/null; then
        echo "$user exists already."
    elif useradd -m -G wheel "$user"; then
        until passwd "$user"; do echo "That did not work; try again."; done
        break
    fi
done

owner=${user:-root}
printf '\nAn SSH public key for %s, one line (empty for none): ' "$owner"
read -r key || exit 0
if [ -n "$key" ]; then
    case $key in
    ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-*\ *|sk-ssh-ed25519@openssh.com\ *|sk-ecdsa-sha2-*\ *)
        home=$(getent passwd "$owner" | cut -d: -f6)
        group=$(id -gn "$owner")
        install -d -m 700 -o "$owner" -g "$group" "$home/.ssh"
        printf '%s\n' "$key" >> "$home/.ssh/authorized_keys"
        chown "$owner:$group" "$home/.ssh/authorized_keys"
        chmod 600 "$home/.ssh/authorized_keys"
        echo "Added." ;;
    *) echo "That is not an SSH public key; none was added." ;;
    esac
fi
# End the setup on the other consoles. agetty made each of them the leader
# of its own process group, which holds its passwd too.
for pid in $(pgrep -f '^/bin/sh /usr/lib/joe/first-setup'); do
    [ "$pid" = $$ ] || kill -TERM -- "-$pid" 2>/dev/null
done
printf '\nDone. Log in below.\n\n'
exit 0
EOT
    chmod 755 "$DESTDIR/usr/lib/joe/serial-getty" "$DESTDIR/usr/lib/joe/modules-load" \
        "$DESTDIR/usr/lib/joe/vt-getty" "$DESTDIR/usr/lib/joe/needs-first-setup" \
        "$DESTDIR/usr/lib/joe/first-setup"

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
