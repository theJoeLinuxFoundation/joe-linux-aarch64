build() {
    mkdir build
    cd build
    # Everything optional is stated so that the build root cannot change the
    # result:
    # - docs: building them needs the DocBook 5 stylesheets and a text
    #   browser; the manual pages come from the book's pre-built tarball.
    # - logind: would link pam_issue, pam_limits and pam_timestamp against
    #   libsystemd, while systemd is to be rebuilt against this package
    #   (pam_systemd). The dependency is kept in that direction only.
    # - audit, libeconf, SELinux, NIS (libnsl, libtirpc), libpwaccess and a
    #   database library for pam_userdb do not exist here.
    meson setup .. \
        --prefix=/usr \
        --buildtype=release \
        -D libdir=lib \
        -D docdir=/usr/share/doc/Linux-PAM-1.7.3 \
        -D docs=disabled \
        -D i18n=enabled \
        -D logind=disabled \
        -D elogind=disabled \
        -D audit=disabled \
        -D econf=disabled \
        -D selinux=disabled \
        -D nis=disabled \
        -D pwaccess=disabled \
        -D pam_userdb=disabled \
        -D examples=false \
        -D systemdunitdir=/usr/lib/systemd/system
    ninja
}

package() {
    cd build
    DESTDIR="$DESTDIR" ninja install
    chmod -v 4755 "$DESTDIR/usr/sbin/unix_chkpwd"

    # Pre-built manual pages (the HTML and text guides in the same tarball go
    # to usr/share/doc, which is not shipped).
    tar -C "$DESTDIR" --no-same-owner --no-same-permissions \
        -xf "$SOURCES/Linux-PAM-1.7.3-docs.tar.xz" usr/share/man

    # Generic configuration that the per-service files include.
    install -vdm755 "$DESTDIR/etc/pam.d"
    cat > "$DESTDIR/etc/pam.d/system-account" << "EOF"
# Begin /etc/pam.d/system-account

account   required    pam_unix.so

# End /etc/pam.d/system-account
EOF

    cat > "$DESTDIR/etc/pam.d/system-auth" << "EOF"
# Begin /etc/pam.d/system-auth

auth      required    pam_unix.so

# End /etc/pam.d/system-auth
EOF

    cat > "$DESTDIR/etc/pam.d/system-session" << "EOF"
# Begin /etc/pam.d/system-session

session   required    pam_unix.so

# Registers the session with systemd-logind. The module belongs to systemd,
# which is built after PAM, so the line lives here.
session   required    pam_loginuid.so
session   optional    pam_systemd.so

# End /etc/pam.d/system-session
EOF

    cat > "$DESTDIR/etc/pam.d/system-password" << "EOF"
# Begin /etc/pam.d/system-password

# use yescrypt hash for encryption, use shadow, and try to use any
# previously defined authentication token (chosen password) set by any
# prior module.
password  required    pam_unix.so       yescrypt shadow try_first_pass

# End /etc/pam.d/system-password
EOF

    # Restrictive fallback: a PAM-aware program without a configuration file
    # of its own is refused.
    cat > "$DESTDIR/etc/pam.d/other" << "EOF"
# Begin /etc/pam.d/other

auth        required        pam_warn.so
auth        required        pam_deny.so
account     required        pam_warn.so
account     required        pam_deny.so
password    required        pam_warn.so
password    required        pam_deny.so
session     required        pam_warn.so
session     required        pam_deny.so

# End /etc/pam.d/other
EOF
}
