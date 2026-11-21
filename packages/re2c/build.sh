# Not in the book: the newest upstream release, built as its BUILD.md says.
# The release tarball carries the pre-generated lexers, parsers and manual
# pages, so neither re2c, Bison nor docutils is needed. Besides re2c, the
# front ends for other languages (re2go, re2rust, re2py, ...) are built, as
# upstream does by default; the libraries (--enable-libs) are not.
build() {
    ./configure --prefix=/usr \
        --disable-debug \
        --disable-docs \
        --disable-lexers \
        --disable-parsers \
        --disable-libs
    make
}

package() {
    make DESTDIR="$DESTDIR" install
}
