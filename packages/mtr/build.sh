# Not in the book: the newest upstream release, built as its README says.
prepare() {
    # make install gives mtr-packet CAP_NET_RAW with setcap, or else makes
    # it set-uid root. joe cannot set file capabilities, so the hook is
    # left out and package() makes it set-uid root; mtr-packet drops its
    # privileges once it has opened its raw sockets.
    sed -i '/^install-exec-hook:/,/^$/{/setcap/d;/chmod u+s/d}' Makefile.in
}

build() {
    # The curses interface (ncursesw) and JSON output (jansson); no GTK
    # interface.
    ./configure --prefix=/usr \
        --sbindir=/usr/sbin \
        --without-gtk \
        --with-ncursesw \
        --with-ncurses \
        --with-jansson \
        --with-ipinfo \
        --enable-ipv6 \
        --enable-bash-completion \
        --with-bashcompletiondir=/usr/share/bash-completion/completions
    make
}

package() {
    make DESTDIR="$DESTDIR" install
    chmod 4755 "$DESTDIR/usr/sbin/mtr-packet"
}
