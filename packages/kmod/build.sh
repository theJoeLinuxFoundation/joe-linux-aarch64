build() {
    mkdir -p build
    cd build
    # openssl (signature display in modinfo) is not part of joe Linux.
    meson setup --prefix=/usr .. \
        --buildtype=release \
        -D manpages=false \
        -D openssl=disabled
    ninja
}

package() {
    cd build
    # Also creates the depmod, insmod, lsmod, modinfo, modprobe and rmmod
    # symlinks in usr/sbin.
    DESTDIR="$DESTDIR" ninja install
}
