build() {
    # The API documentation needs Doxygen.
    ./configure --prefix=/usr \
        --disable-static \
        --without-doxygen
    make
}

package() {
    make DESTDIR="$DESTDIR" install
}
