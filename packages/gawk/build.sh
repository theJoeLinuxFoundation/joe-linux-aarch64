prepare() {
    # Keep the "extras" (profile.d snippets) out of the installation.
    sed -i 's/extras//' Makefile.in
}

build() {
    ./configure --prefix=/usr
    make
}

package() {
    make DESTDIR="$DESTDIR" install
    # The installation already makes awk a link to gawk; do the same for
    # the manual page.
    ln -sf gawk.1 "$DESTDIR/usr/share/man/man1/awk.1"
}
