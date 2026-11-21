# Not in the book: the newest upstream release, built as its README says.
build() {
    # The system oniguruma rather than the copy in vendor/. The manual
    # page is the prebuilt one (jq.1.prebuilt); rebuilding it needs Python
    # modules joe Linux does not have.
    ./configure --prefix=/usr \
        --disable-static \
        --with-oniguruma=yes \
        --enable-decnum \
        --disable-docs \
        --disable-valgrind
    make
}

package() {
    make DESTDIR="$DESTDIR" install
}
