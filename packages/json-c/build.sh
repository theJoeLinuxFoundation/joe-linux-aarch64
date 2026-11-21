build() {
    mkdir build
    cd build
    cmake -D CMAKE_INSTALL_PREFIX=/usr \
        -D CMAKE_BUILD_TYPE=Release \
        -D CMAKE_INSTALL_LIBDIR=lib \
        -D BUILD_STATIC_LIBS=OFF \
        ..
    make
}

package() {
    cd build
    make DESTDIR="$DESTDIR" install
}
