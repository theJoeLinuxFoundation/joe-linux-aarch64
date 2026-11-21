prepare() {
    # uv_os_tmpdir() falls back to joe's temporary directory.
    sed -i 's|"/data/local/tmp"|"/tmp"|' src/unix/core.c
    # random.c selects getentropy on bionic API 28 and later. CMake builds
    # the implementation there, but the Automake source list omits it.
    sed -i '/^if ANDROID$/a libuv_la_SOURCES += src/unix/random-getentropy.c' Makefile.am
    sh autogen.sh
}

build() {
    ./configure --prefix=/usr --disable-static
    make
}

package() {
    make DESTDIR="$DESTDIR" install
}
