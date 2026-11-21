# Following the book's tree page.
prepare() {
    # bionic provides mbstowcs and joe's strverscmp patch supplies version sorting.
    sed -i '/^#ifdef __ANDROID$/,/^#endif$/d' tree.h
    sed -i 's/!defined(__linux__) || defined(__ANDROID__)/!defined(__linux__)/' \
        tree.h strverscmp.c
}

build() {
    make CC="$CC"
}

package() {
    # tree's Makefile uses DESTDIR as the directory for the program, so the
    # book's "make PREFIX=/usr MANDIR=/usr/share/man install" is spelled out
    # with the staging directory instead.
    install -Dm755 tree "$DESTDIR/usr/bin/tree"
    install -Dm644 doc/tree.1 "$DESTDIR/usr/share/man/man1/tree.1"
}
