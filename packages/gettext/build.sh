build() {
    # --undefined-version: libtextstyle's version script always exports its
    # iconv stream, which is only compiled where configure finds iconv
    # working. bionic's iconv knows few encodings and fails configure's
    # test; GNU ld passes over the missing symbol, lld refuses without this.
    ./configure --prefix=/usr \
        --disable-static \
        --docdir=/usr/share/doc/gettext-1.0 \
        LDFLAGS=-Wl,--undefined-version
    make
}

package() {
    make DESTDIR="$DESTDIR" install
    # No preloadable_libintl.so: gettext builds it for glibc, whose own
    # gettext it is preloaded over. Here libintl.so is the only gettext.
}
