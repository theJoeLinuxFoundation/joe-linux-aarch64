package() {
    install -d "$DESTDIR/etc"
    install -m 644 services protocols "$DESTDIR/etc"
}
