build() {
    ./configure --prefix=/usr \
        --disable-static \
        --docdir=/usr/share/doc/flex-2.6.4
    make
}

package() {
    make DESTDIR="$DESTDIR" install

    # Some programs still call lex.
    ln -sv flex "$DESTDIR/usr/bin/lex"
    ln -sv flex.1 "$DESTDIR/usr/share/man/man1/lex.1"
}
