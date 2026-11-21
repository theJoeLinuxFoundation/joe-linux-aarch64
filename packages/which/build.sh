prepare() {
    # Bionic supplies getopt_long. Its declarations must match the library;
    # the bundled header declares getopt() with no arguments in C23.
    rm getopt.h
}

build() {
    ./configure --prefix=/usr
    make
}

package() {
    make DESTDIR="$DESTDIR" install
}
