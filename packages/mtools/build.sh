# Not in the book: the newest upstream release, built as its INSTALL file
# says. The Info manual comes ready-made in the tarball.
build() {
    # floppyd serves a floppy drive to X sessions and needs libX11 and
    # libXau; it is not wanted, as in the Makefile's iso-tools target.
    # Bionic iconv handles Unicode, but cannot convert DOS code pages.
    # Use the upstream built-in tables, including the default CP850.
    ac_cv_header_iconv_h=no ./configure --prefix=/usr \
        --sysconfdir=/etc \
        --disable-floppyd \
        --without-x
    make
}

package() {
    make DESTDIR="$DESTDIR" install
}
