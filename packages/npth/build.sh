prepare() {
    # nPth uses pthread_create. It probes for pthread_cancel to distinguish
    # glibc's libpthread, but bionic provides threads in libc without cancellation.
    sed -i '/^#/!s/pthread_cancel/pthread_create/g' configure
}

build() {
    ./configure --prefix=/usr --disable-static
    make
}

package() {
    make DESTDIR="$DESTDIR" install
}
