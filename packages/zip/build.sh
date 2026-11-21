build() {
    # The code predates C99; the book pins the dialect.
    make -f unix/Makefile generic CC="$CC -std=gnu89"
}

package() {
    # The makefile has no DESTDIR; prefix is only used to place files.
    make CC="$CC -std=gnu89" prefix="$DESTDIR/usr" MANDIR="$DESTDIR/usr/share/man/man1" \
        -f unix/Makefile install
}
