# Not in the book: the newest upstream release (upstream has made none since
# 2019), built with its Makefile as README.md describes.
#
# src/opt.c uses x86 intrinsics. Build src/ref.c for generic AArch64.
# LIBRARY_REL keeps the library in /usr/lib, and ARGON2_VERSION supplies
# the version for libargon2.pc.
_make() {
    make CC="$CC" OPTTEST=1 OPTTARGET=armv8-a LIBRARY_REL=lib PREFIX=/usr ARGON2_VERSION="$PKG_VERSION" "$@"
}

build() {
    _make
}

package() {
    _make DESTDIR="$DESTDIR" install
    rm "$DESTDIR/usr/lib/libargon2.a"
    install -Dm644 man/argon2.1 "$DESTDIR/usr/share/man/man1/argon2.1"
}
