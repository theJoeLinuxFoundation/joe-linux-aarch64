# Not in the book: the newest upstream release, built as its docs/INSTALL
# says.
build() {
    ./configure --prefix=/usr \
        --with-ncurses \
        --disable-debugging \
        --disable-profiling
    make
}

package() {
    make DESTDIR="$DESTDIR" install
}
