# Not in the book: the newest upstream release, built as its INSTALL says.
build() {
    # The netlink interface (libmnl) is what newer settings need; the old
    # ioctl interface is built in as well.
    ./configure --prefix=/usr \
        --enable-netlink \
        --enable-pretty-dump \
        --with-bash-completion-dir=/usr/share/bash-completion/completions
    make
}

package() {
    make DESTDIR="$DESTDIR" install
}
