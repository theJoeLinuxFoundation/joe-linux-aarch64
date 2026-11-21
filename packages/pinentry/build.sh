build() {
    # Use curses on the console and over ssh. The GNOME prompt needs Gcr
    # and a session bus, and saving passphrases in a keyring needs libsecret.
    ./configure --prefix=/usr \
        --disable-pinentry-tty \
        --enable-pinentry-curses \
        --disable-fallback-curses \
        --disable-pinentry-gnome3 \
        --disable-libsecret \
        --disable-pinentry-emacs \
        --disable-inside-emacs \
        --disable-pinentry-gtk2 \
        --disable-pinentry-qt \
        --disable-pinentry-qt5 \
        --disable-pinentry-qt4 \
        --disable-pinentry-tqt \
        --disable-pinentry-fltk \
        --disable-pinentry-efl
    make
}

package() {
    make DESTDIR="$DESTDIR" install
    test "$(readlink "$DESTDIR/usr/bin/pinentry")" = pinentry-curses
}
