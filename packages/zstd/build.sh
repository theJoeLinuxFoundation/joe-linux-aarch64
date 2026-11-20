# HAVE_LZ4=0: lz4 is not part of joe Linux; never pick it up. zlib and xz
# support in the zstd program is detected by its Makefile.
build() {
    make prefix=/usr HAVE_LZ4=0
}

package() {
    make prefix=/usr HAVE_LZ4=0 DESTDIR="$DESTDIR" install
    rm -v "$DESTDIR/usr/lib/libzstd.a"
}
