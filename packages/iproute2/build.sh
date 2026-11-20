prepare() {
    # arpd needs Berkeley DB, which is not shipped.
    sed -i /ARPD/d Makefile
    rm -f man/man8/arpd.8
}

build() {
    make NETNS_RUN_DIR=/run/netns
}

package() {
    make DESTDIR="$DESTDIR" NETNS_RUN_DIR=/run/netns SBINDIR=/usr/sbin install
}
