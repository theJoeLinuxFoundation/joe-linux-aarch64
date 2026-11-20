build() {
    ./configure --prefix=/usr --localstatedir=/var/lib/locate
    make
}

package() {
    make DESTDIR="$DESTDIR" install

    # /var is not packaged: the locate database directory is made at boot.
    rmdir "$DESTDIR/var/lib/locate" "$DESTDIR/var/lib" "$DESTDIR/var"
    install -d "$DESTDIR/usr/lib/tmpfiles.d"
    cat > "$DESTDIR/usr/lib/tmpfiles.d/joe-findutils.conf" <<'EOT'
d /var/lib/locate 0755 root root -
EOT
}
