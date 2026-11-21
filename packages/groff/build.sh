build() {
    # PAGE: the default paper size, which /etc/papersize overrides at run
    # time. A4 is the format of most of the world.
    # The X11 previewer (gxditview), encoding detection through uchardet and
    # embedding the URW fonts in PDF output need things the base system does
    # not have. Refuse each by name so additions to the shared build root
    # cannot enable those features.
    PAGE=A4 ./configure --prefix=/usr \
        --without-x \
        --with-uchardet=no \
        --without-urw-fonts
    # The book builds groff with a single job.
    make -j1
}

package() {
    make DESTDIR="$DESTDIR" install
}
