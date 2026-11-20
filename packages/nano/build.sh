build() {
    # libmagic (from file, part of the base system) recognises file types for
    # syntax highlighting when the file name does not; nano then also links
    # zlib, which libmagic names in its pkg-config file.
    ./configure --prefix=/usr \
        --sysconfdir=/etc \
        --enable-utf8 \
        --enable-libmagic \
        --docdir=/usr/share/doc/nano-9.3
    make
}

package() {
    make DESTDIR="$DESTDIR" install

    # The annotated sample with every setting commented out, except that the
    # syntax definitions in /usr/share/nano are loaded.
    install -Dm644 doc/sample.nanorc "$DESTDIR/etc/nanorc"
    sed -i 's|^# include /usr/share/nano/\*\.nanorc$|include /usr/share/nano/*.nanorc|' \
        "$DESTDIR/etc/nanorc"
    grep -qx 'include /usr/share/nano/\*\.nanorc' "$DESTDIR/etc/nanorc"
}
