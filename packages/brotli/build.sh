prepare() {
    # Build the Python module against the shared libraries instead of
    # compiling a second copy of the sources into it, without needing the
    # "pkgconfig" Python module.
    sed -e '/libraries +=/s/=.*/= [required_system_library[3:]]/' \
        -e '/package_configuration/d' \
        -e '/pkgconfig/d' \
        -i setup.py
}

build() {
    mkdir build
    cd build
    cmake -D CMAKE_INSTALL_PREFIX=/usr \
        -D CMAKE_BUILD_TYPE=Release \
        -D CMAKE_INSTALL_LIBDIR=lib \
        -G Ninja ..
    ninja
    cd ..

    # The book builds the Python module after "ninja install". Here the
    # libraries are not in the build root yet, so point the compiler at the
    # headers in the source tree and the libraries just built.
    CFLAGS="-I$PWD/c/include" LDFLAGS="-L$PWD/build" USE_SYSTEM_BROTLI=1 \
        pip3 wheel -w dist --no-build-isolation --no-deps --no-cache-dir "$PWD"
}

package() {
    DESTDIR="$DESTDIR" ninja -C build install
    pip3 install --no-index --no-deps --no-user --ignore-installed --no-warn-script-location \
        --root "$DESTDIR" --find-links dist Brotli
}
