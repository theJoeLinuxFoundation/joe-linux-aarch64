# The same settings must reach both make runs. pci.ids is read from hwdata,
# which ships it uncompressed (ZLIB=no). libkmod names the kernel modules for
# `lspci -k`, udev's hwdb is a second source of names, DNS is the resolver in
# bionic. MANDIR is otherwise guessed from the machine doing the build.
_make() {
    make CC="$CC" AR="$AR" RANLIB="$RANLIB" STRIP= \
        PREFIX=/usr \
        SHAREDIR=/usr/share/hwdata \
        MANDIR=/usr/share/man \
        SHARED=yes \
        ZLIB=no \
        DNS=yes \
        LIBKMOD=yes \
        HWDB=yes \
        "$@"
}

prepare() {
    # Neither pci.ids nor update-pciids is installed: the list belongs to
    # hwdata and is updated with it.
    sed -r '/INSTALL/{/PCI_IDS|update-pciids /d; s/update-pciids.8//}' \
        -i Makefile
}

build() {
    _make
}

package() {
    _make DESTDIR="$DESTDIR" install install-lib
    chmod -v 755 "$DESTDIR/usr/lib/libpci.so"
}
