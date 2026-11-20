build() {
    # Following the book's make page, with GNU Guile extensions switched off
    # explicitly: configure links Guile whenever guile-3.0 is installed.
    ./configure --prefix=/usr --without-guile
    make
}

package() {
    make DESTDIR="$DESTDIR" install
}
