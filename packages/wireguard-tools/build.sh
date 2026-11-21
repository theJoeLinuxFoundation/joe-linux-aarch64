# Not in the book: the newest upstream release, built as its README says.
# Install wg-quick and its bash completions. The optional dynamod service
# brings up wg0 and tears it down on stop.
_wg_make() {
    make -C src CC="$CC" \
        PREFIX=/usr \
        SYSCONFDIR=/etc \
        RUNSTATEDIR=/run \
        WITH_WGQUICK=yes \
        WITH_SYSTEMDUNITS=no \
        WITH_BASHCOMPLETION=yes \
        "$@"
}

build() {
    _wg_make
}

package() {
    _wg_make DESTDIR="$DESTDIR" install

    install -d "$DESTDIR/usr/lib/dynamod/services"
    install -m644 /recipe/*.toml "$DESTDIR/usr/lib/dynamod/services/"
}
