# The same paths are used to link the programs and to write libkeyutils.pc.
_keyutils_make() {
    # Clang warns about unused code in keyctl_watch and request-key.
    # Keep the warnings visible without upstream’s blanket -Werror.
    make CC="$CC" CXX="$CXX" CFLAGS="-g -Wall" NO_ARLIB=1 LIBDIR=/usr/lib USRLIBDIR=/usr/lib \
        BINDIR=/usr/bin SBINDIR=/usr/sbin "$@"
}

build() {
    _keyutils_make
}

package() {
    _keyutils_make DESTDIR="$DESTDIR" install
}
