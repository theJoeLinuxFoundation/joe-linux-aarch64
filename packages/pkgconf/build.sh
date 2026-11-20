# The LFS book builds pkgconf with meson run from its source tree. That needs
# a Python with the zlib module, which the temporary Python of the bootstrap
# does not have, so joe uses the configure script pkgconf still ships.
build() {
    ./configure --prefix=/usr --libdir=/usr/lib --disable-static
    make
}

package() {
    make DESTDIR="$DESTDIR" install

    # Compatibility with the original pkg-config.
    ln -sv pkgconf "$DESTDIR/usr/bin/pkg-config"
    ln -sv pkgconf.1 "$DESTDIR/usr/share/man/man1/pkg-config.1"
}
