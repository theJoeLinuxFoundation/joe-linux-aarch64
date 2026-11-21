# Not in the book: the newest upstream release, built as its documentation
# ("Installation") describes. The checksum is that of the same file on the
# GitHub release.
build() {
    ./configure --prefix=/usr --disable-static
    make
}

package() {
    make DESTDIR="$DESTDIR" install
}
