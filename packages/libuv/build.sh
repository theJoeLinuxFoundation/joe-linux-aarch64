prepare() {
    # uv_os_tmpdir() falls back to joe's temporary directory.
    sed -i 's|"/data/local/tmp"|"/tmp"|' src/unix/core.c
    sh autogen.sh
}

build() {
    ./configure --prefix=/usr --disable-static
    make
}

package() {
    make DESTDIR="$DESTDIR" install
}
