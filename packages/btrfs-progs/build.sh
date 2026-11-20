build() {
    # No sphinx (documentation), no e2fsprogs (convert), no lzo, and the
    # Python bindings are not wanted.
    ./configure --prefix=/usr \
        --disable-static \
        --disable-documentation \
        --disable-python \
        --disable-convert \
        --disable-lzo
    make
}

package() {
    make DESTDIR="$DESTDIR" install

    # The tarball ships ready-made manual pages; btrfs-convert is not built.
    local i
    for i in 5 8; do
        install -d "$DESTDIR/usr/share/man/man$i"
        install -m 644 Documentation/*."$i" "$DESTDIR/usr/share/man/man$i"
    done
    rm "$DESTDIR/usr/share/man/man8/btrfs-convert.8"
}
