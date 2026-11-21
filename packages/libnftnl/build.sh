# Not in the book: the newest upstream release, built as its README says.
build() {
    ./configure --prefix=/usr --disable-static
    make
}

package() {
    make DESTDIR="$DESTDIR" install
}
