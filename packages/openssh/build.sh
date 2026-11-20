build() {
    # The first six switches are the book's. Authentication goes through PAM.
    # Everything else optional is refused by name so that the shared build
    # root cannot switch it on: Kerberos (krb5 is there, for the desktop),
    # libedit, ldns, SELinux, audit, and FIDO keys built in (libfido2).
    # --with-xauth only records where xauth would be, for X11 forwarding on a
    # system that has it.
    ./configure --prefix=/usr \
        --sysconfdir=/etc/ssh \
        --with-privsep-path=/var/lib/sshd \
        --with-default-path=/usr/bin \
        --with-superuser-path=/usr/sbin:/usr/bin \
        --with-pid-dir=/run \
        --with-pam \
        --with-xauth=/usr/bin/xauth \
        --without-kerberos5 \
        --without-libedit \
        --without-ldns \
        --without-selinux \
        --without-audit \
        --without-security-key-builtin
    make
}

package() {
    # install-nokeys: host keys belong to a machine, not to a package. They
    # are made by sshd-keygen.service below.
    make DESTDIR="$DESTDIR" install-nokeys
    install -v -m755 contrib/ssh-copy-id "$DESTDIR/usr/bin"
    install -v -m644 contrib/ssh-copy-id.1 "$DESTDIR/usr/share/man/man1"

    # Passwords are checked by PAM, with the same rules as a console login:
    # the file is shadow's /etc/pam.d/login (Beyond LFS derives it from that
    # file with sed).
    echo "UsePAM yes" >> "$DESTDIR/etc/ssh/sshd_config"
    install -d "$DESTDIR/etc/pam.d"
    cat > "$DESTDIR/etc/pam.d/sshd" << "EOF"
# Set failure delay before next prompt to 3 seconds
auth      optional    pam_faildelay.so  delay=3000000

# Check to make sure that the user is allowed to login
auth      requisite   pam_nologin.so

# include system auth settings
auth      include     system-auth

# check access for the user
account   required    pam_access.so

# include system account settings
account   include     system-account

# Set default environment variables for the user
session   required    pam_env.so

# Set resource limits for the user
session   required    pam_limits.so

# include system session and password settings
session   include     system-session
password  include     system-password
EOF

    # The unprivileged user of the pre-authentication process, with the
    # book's ids, and its empty chroot directory (the book's "install -g sys
    # -m700 -d /var/lib/sshd"; /var is not packaged).
    install -d "$DESTDIR/usr/lib/sysusers.d" "$DESTDIR/usr/lib/tmpfiles.d"
    cat > "$DESTDIR/usr/lib/sysusers.d/openssh.conf" << "EOF"
g sshd 50
u sshd 50:50 "sshd PrivSep" /var/lib/sshd /usr/bin/false
EOF
    cat > "$DESTDIR/usr/lib/tmpfiles.d/openssh.conf" << "EOF"
d /var/lib/sshd 0700 root sys -
EOF

    # dynamod's services in place of blfs-systemd-units': the host keys are
    # made on the machine itself the first time (a package cannot ship
    # them), then sshd runs in the foreground under the service manager.
    # joe's base system offers ssh, so sshd starts at boot.
    install -d "$DESTDIR/usr/lib/dynamod/services"
    cat > "$DESTDIR/usr/lib/dynamod/services/sshd-keygen.toml" << "EOT"
[service]
name = "sshd-keygen"
exec = ["/usr/bin/ssh-keygen", "-A"]
type = "oneshot"
remain-after-exit = true

[restart]
policy = "temporary"

[dependencies]
after = ["fstab-mount"]

[readiness]
type = "none"
EOT
    cat > "$DESTDIR/usr/lib/dynamod/services/sshd.toml" << "EOT"
[service]
name = "sshd"
exec = ["/usr/sbin/sshd", "-D", "-e"]
type = "simple"

[restart]
policy = "permanent"
delay = "2s"

[dependencies]
requires = ["sshd-keygen"]
after = ["loopback", "dhcpcd"]

[readiness]
type = "none"
EOT
}
