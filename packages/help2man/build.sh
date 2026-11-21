# Not in the book: the newest upstream release, built as its INSTALL file
# says.
build() {
    # Localised manual pages need the Locale::gettext Perl module and a
    # preload library; joe Linux has neither, so English only.
    ./configure --prefix=/usr \
        --disable-nls
    make
}

package() {
    make DESTDIR="$DESTDIR" install
}
