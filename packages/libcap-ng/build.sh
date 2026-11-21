# Not in the book: the newest upstream release, built as its README says.
# The archive of a tag has no configure script; autogen.sh makes it, which
# is these two commands.
prepare() {
    touch NEWS
    autoreconf -fiv
}

build() {
    # No Python bindings (they need SWIG), and no cap-audit (it needs
    # libbpf, bpftool and libaudit).
    ./configure --prefix=/usr \
        --disable-static \
        --without-python \
        --without-python3 \
        --disable-cap-audit
    make
}

package() {
    make DESTDIR="$DESTDIR" install
}
