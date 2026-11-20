prepare() {
    # Make the bzegrep, bzless, ... aliases relative symlinks, and install the
    # manual pages under /usr/share/man.
    sed -i 's@\(ln -s -f \)$(PREFIX)/bin/@\1@' Makefile
    sed -i "s@(PREFIX)/man@(PREFIX)/share/man@g" Makefile
}

build() {
    # Its makefiles name gcc, ar and ranlib; joe's are LLVM's (the driver's
    # CC, AR and RANLIB).
    local tools=(CC="$CC" AR="$AR" RANLIB="$RANLIB")

    # The shared library and a bzip2 linked against it.
    make -f Makefile-libbz2_so "${tools[@]}"
    make clean

    # Not plain "make": its default target also runs the test suite.
    make "${tools[@]}" libbz2.a bzip2 bzip2recover
}

package() {
    # This Makefile has no DESTDIR; PREFIX is only used as an install location.
    make CC="$CC" AR="$AR" RANLIB="$RANLIB" PREFIX="$DESTDIR/usr" install

    cp -av libbz2.so.* "$DESTDIR/usr/lib"
    ln -sfv libbz2.so.1.0.8 "$DESTDIR/usr/lib/libbz2.so"
    ln -sfv libbz2.so.1.0.8 "$DESTDIR/usr/lib/libbz2.so.1"

    # Replace the statically linked bzip2 and its two copies.
    cp -v bzip2-shared "$DESTDIR/usr/bin/bzip2"
    local i
    for i in bzcat bunzip2; do
        ln -sfv bzip2 "$DESTDIR/usr/bin/$i"
    done

    rm -fv "$DESTDIR/usr/lib/libbz2.a"
}
