# Not in the book: the C version, 1.22, built as its README says. ncdu 2.x
# is written in Zig and its newest release (2.9.2) builds only with Zig 0.14
# or 0.15, while joe Linux has Zig 0.17. 1.22 is the newest release of the
# C version, which upstream keeps alongside 2.x.
build() {
    ./configure --prefix=/usr \
        --with-ncursesw \
        --with-shell=/bin/sh
    make
}

package() {
    make DESTDIR="$DESTDIR" install
}
