prepare() {
    # Do not move already installed libraries to <name>.old on installation.
    sed -i '/MV.*old/d' Makefile.in
    sed -i '/{OLDSUFF}/c:' support/shlib-install

    # Do not hard-code library search paths (rpath) into the shared libraries.
    sed -i 's/-Wl,-rpath,[^ ]*//' support/shobj-conf

    # Fix a problem identified upstream specifically for readline 8.3.
    sed -e '270a\
     else\
       chars_avail = 1;'      \
        -e '288i\   result = -1;' \
        -i.orig input.c
}

build() {
    ./configure --prefix=/usr \
        --disable-static \
        --with-curses \
        --docdir=/usr/share/doc/readline-8.3
    # Link the shared libraries against libncursesw.
    make SHLIB_LIBS="-lncursesw"
}

package() {
    make SHLIB_LIBS="-lncursesw" DESTDIR="$DESTDIR" install
}
