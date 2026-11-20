prepare() {
    patch -Np1 -i "$SOURCES/tar-1.35-acl_fix-1.patch"
}

build() {
    # LIBS: tar's programs are linked without $(LIBINTL), which glibc, whose
    # libc has gettext, never shows; on bionic gettext is libintl's.
    FORCE_UNSAFE_CONFIGURE=1 ./configure --prefix=/usr LIBS=-lintl
    make
}

package() {
    make DESTDIR="$DESTDIR" install
}
