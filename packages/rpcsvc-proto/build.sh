build() {
    # The prefix is /usr by default (AC_PREFIX_DEFAULT).
    ./configure --prefix=/usr --sysconfdir=/etc
    make
}

package() {
    make DESTDIR="$DESTDIR" install
}
