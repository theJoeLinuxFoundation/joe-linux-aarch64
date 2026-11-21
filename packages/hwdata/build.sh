build() {
    # --disable-blacklist: do not install a modprobe.d file blacklisting
    # kernel modules.
    ./configure --prefix=/usr --libdir=/usr/lib --disable-blacklist
}

package() {
    make DESTDIR="$DESTDIR" install
}
