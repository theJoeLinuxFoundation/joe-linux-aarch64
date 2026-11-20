# OpenDoas, the portable doas, is how joe Linux becomes root (joe-base);
# sudo is still packaged for what depends on it. Beyond LFS has no page for
# it, so this follows upstream's README.

build() {
    # Authentication through PAM, like login and su. The timestamp files
    # make doas.conf's persist option work (a password is good for five
    # minutes in the shell it was given in), as sudo's credential cache
    # does; upstream leaves them out unless asked, because OpenBSD keeps
    # that state in its kernel instead. They are kept in /run/doas, which
    # doas makes itself.
    ./configure --prefix=/usr --with-pam --with-timestamp
    grep -qx '#define USE_PAM' config.h
    grep -qx '#define USE_TIMESTAMP' config.h
    # parse.y goes through make's yacc rule; name the yacc rather than rely
    # on the build root having a program called yacc.
    make YACC="bison -y"
}

package() {
    # Installs doas set-uid root (4755), owned by root, which is who runs
    # this, and upstream's /etc/pam.d/doas, which is replaced below.
    make DESTDIR="$DESTDIR" install
    test -u "$DESTDIR/usr/bin/doas"

    # Members of the administrators' group, wheel (gid 97, joe-filesystem),
    # may run anything after giving their own password, as with sudo; root
    # may too, without one. doas reads this one file and has no directory of
    # drop-ins, so the live medium appends its rule to it at boot
    # (packages/joe-live) rather than adding a file beside it.
    cat > "$DESTDIR/etc/doas.conf" << "EOF"
# Who may run what as whom: doas.conf(5). The last rule that matches decides.

permit persist :wheel
permit nopass root
EOF
    chmod 0400 "$DESTDIR/etc/doas.conf"

    # Upstream's file is laid out for the distributions whose system-auth
    # holds every PAM stage; Linux-PAM's here keeps accounts and sessions in
    # system-account and system-session (packages/linux-pam), as sudo's file
    # does. doas makes the command's environment itself and never reads
    # PAM's, so pam_env has nothing to do and is left out.
    cat > "$DESTDIR/etc/pam.d/doas" << "EOF"
# Begin /etc/pam.d/doas

auth      include     system-auth
account   include     system-account
session   include     system-session

# End /etc/pam.d/doas
EOF
    chmod 644 "$DESTDIR/etc/pam.d/doas"

    # "sudo" at an interactive prompt, the name people reach for, runs doas.
    # Only the name carries over: doas has options of its own (doas(1)) and
    # does not take sudo's. This directory is read by every interactive
    # bash, root's included (joe-filesystem); aliases mean nothing to
    # scripts, which find no sudo. Where sudo is installed (something that
    # needs it depends on it), the name is left to it.
    install -d "$DESTDIR/usr/lib/joe/profile.d"
    cat > "$DESTDIR/usr/lib/joe/profile.d/doas.sh" << "EOF"
# doas answers to sudo where sudo is not installed (packages/opendoas).
if [ ! -e /usr/bin/sudo ]; then
    alias sudo=doas
fi
EOF
}
