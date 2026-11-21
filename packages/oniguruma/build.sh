# Not in the book: the newest upstream release, built as its README says.
build() {
    # The POSIX-compatible API (onigposix.h) is left out, as upstream's
    # default; nothing here uses it.
    ./configure --prefix=/usr \
        --disable-static \
        --disable-posix-api
    make
}

package() {
    make DESTDIR="$DESTDIR" install
}
