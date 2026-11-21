# Following the book's dash page, installed in /usr/bin. The book's
# "ln -svf dash /bin/sh" is left out: /usr/bin/sh is bash's. No line editing,
# since libedit has no recipe.
build() {
    ./configure --prefix=/usr \
        --bindir=/usr/bin \
        --mandir=/usr/share/man \
        --without-libedit
    make
}

package() {
    make DESTDIR="$DESTDIR" install
}
