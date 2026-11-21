prepare() {
    # Bionic's startup objects use .init_array and .fini_array. There are
    # no _init or _fini symbols for lld to export from this library.
    sed -i -E '/^[[:space:]]*_(init|fini);$/d' src/libpopt.vers
}

build() {
    ./configure --prefix=/usr --disable-static
    make
}

package() {
    make DESTDIR="$DESTDIR" install
}
