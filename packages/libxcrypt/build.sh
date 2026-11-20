prepare() {
    # Fix required by glibc 2.43 and later.
    sed -i '/strchr/s/const//' lib/crypt-{sm3,gost}-yescrypt.c
}

build() {
    # strong,glibc: the hashes recommended today plus those of the old glibc
    # libcrypt. The obsolete API (libcrypt.so.1) is only needed by binary-only
    # programs and is not built.
    ./configure --prefix=/usr \
        --enable-hashes=strong,glibc \
        --enable-obsolete-api=no \
        --disable-static \
        --disable-failure-tokens
    make
}

package() {
    make DESTDIR="$DESTDIR" install
}
