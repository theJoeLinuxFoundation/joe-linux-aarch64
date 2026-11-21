prepare() {
    # An unnecessary call to git.
    sed -i "/'git'/,+3d" meson.build
}

build() {
    mkdir build
    cd build
    # The Python bindings (deprecated upstream) and the documentation are off
    # unless asked for; the book asks for neither.
    meson setup .. \
        --prefix=/usr \
        --buildtype=release \
        -D libdir=lib \
        -D history=enabled \
        -D icu=enabled
    ninja
}

package() {
    cd build
    DESTDIR="$DESTDIR" ninja install

    # Only the shared library is installed: keep the static link flags (and
    # with them ICU) out of what xml2-config hands to other packages.
    sed "s/--static/--shared/" -i "$DESTDIR/usr/bin/xml2-config"
}
