build() {
    mkdir build
    cd build
    # runtime=libidn2: what "auto" picks when libidn2 is there, stated so that
    # ICU in the build root cannot change it. python is needed to compile the
    # built-in list and by the installed psl-make-dafsa script.
    meson setup --prefix=/usr \
        --buildtype=release \
        -D libdir=lib \
        -D runtime=libidn2 \
        ..
    ninja
}

package() {
    cd build
    DESTDIR="$DESTDIR" ninja install
}
