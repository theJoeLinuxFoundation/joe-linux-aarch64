# Following the book's Traceroute page (basicnet/traceroute).
build() {
    make
}

package() {
    make prefix=/usr DESTDIR="$DESTDIR" install
    ln -sfv traceroute "$DESTDIR/usr/bin/traceroute6"
    ln -sfv traceroute.8 "$DESTDIR/usr/share/man/man8/traceroute6.8"
    # The book's "rm /usr/share/man/man1/traceroute.1" removes the page of
    # inetutils' traceroute from the system; nothing here installs one.
}
