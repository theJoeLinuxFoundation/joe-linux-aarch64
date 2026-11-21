# Not in the book: the newest upstream release, built with its Makefile as
# README.md describes. The library is BSD-2-Clause, xxhsum GPL-2.0-or-later.
build() {
    make CC="$CC" AR="$AR" PREFIX=/usr
}

package() {
    # Only the shared libxxhash, the headers, xxhsum and its links (xxh32sum,
    # xxh64sum, xxh128sum, xxh3sum) and the manual pages: the "install"
    # target would add libxxhash.a.
    make CC="$CC" AR="$AR" PREFIX=/usr DESTDIR="$DESTDIR" \
        install_libxxhash install_libxxhash.includes install_libxxhash.pc \
        install_xxhsum install_man
}
