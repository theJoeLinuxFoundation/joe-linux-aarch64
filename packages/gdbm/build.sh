build() {
    # readline (and through it ncurses) is used by the interactive gdbmtool.
    ./configure --prefix=/usr \
        --disable-static \
        --enable-libgdbm-compat \
        --with-readline
    make
}

package() {
    make DESTDIR="$DESTDIR" install
}
