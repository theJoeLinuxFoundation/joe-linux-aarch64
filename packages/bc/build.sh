build() {
    # -G: leave out the tests that need an installed bc; -r: use readline.
    CC='cc -std=c99' ./configure --prefix=/usr -G -O3 -r
    make
}

package() {
    make DESTDIR="$DESTDIR" install
}
