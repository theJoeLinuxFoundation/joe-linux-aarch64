build() {
    # libxml2 has no Python bindings, so there can be none here; the
    # deprecated EXSLT crypto extension (libgcrypt) is off by default.
    ./configure --prefix=/usr \
        --disable-static \
        --without-python \
        --docdir=/usr/share/doc/libxslt-1.1.45
    make
}

package() {
    make DESTDIR="$DESTDIR" install
}
