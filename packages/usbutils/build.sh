build() {
    mkdir build
    cd build
    meson setup .. \
        --prefix=/usr \
        --buildtype=release
    ninja
}

package() {
    cd build
    DESTDIR="$DESTDIR" ninja install
}
