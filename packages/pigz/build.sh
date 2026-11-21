# Not in the book: the newest upstream release, built with its Makefile as
# its README says. The Zopfli code pigz uses for -11 is part of the source.
build() {
    make CC="$CC" LDFLAGS="${LDFLAGS:-}" pigz
}

package() {
    install -Dm755 pigz "$DESTDIR/usr/bin/pigz"
    # pigz decompresses when it is called as unpigz.
    ln -s pigz "$DESTDIR/usr/bin/unpigz"
    install -Dm644 pigz.1 "$DESTDIR/usr/share/man/man1/pigz.1"
    ln -s pigz.1 "$DESTDIR/usr/share/man/man1/unpigz.1"
}
