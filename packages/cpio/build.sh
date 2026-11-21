prepare() {
    # From the book: give the xstat function pointer a prototype, which
    # GCC 15 (C23) requires.
    sed -e "/^extern int (\*xstat)/s/()/(const char * restrict,  struct stat * restrict)/" \
        -i src/extern.h
    sed -e "/^int (\*xstat)/s/()/(const char * restrict,  struct stat * restrict)/" \
        -i src/global.c
}

build() {
    # --enable-mt builds the mt tape program, as in the book. The rmt
    # program is tar's, so cpio installs none.
    ./configure --prefix=/usr \
        --enable-mt \
        --with-rmt=/usr/libexec/rmt
    make
}

package() {
    make DESTDIR="$DESTDIR" install
}
