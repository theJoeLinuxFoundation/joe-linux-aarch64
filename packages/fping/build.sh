# Not in the book: the newest upstream release, built as its INSTALL says.
build() {
    # IPv4 and IPv6 in one binary, with kernel time stamps (the defaults,
    # stated). Installed in /usr/bin, as Debian and Arch do, for use with
    # unprivileged ICMP sockets.
    ./configure --prefix=/usr \
        --sbindir=/usr/bin \
        --enable-ipv4 \
        --enable-ipv6 \
        --enable-timestamp
    make
}

package() {
    make DESTDIR="$DESTDIR" install
}
