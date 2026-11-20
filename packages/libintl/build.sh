# GNU libintl alone, from gettext's source. glibc and musl have gettext(),
# bindtextdomain() and the rest in the C library; bionic does not, so every
# program that translates its messages needs libintl.so (the build driver
# links it where it is used). gettext's tools are a package of their own,
# which a running system does not need: libintl is 180 KB of its 23 MB.
# intl/ is configured and built as part of gettext-runtime (its Makefile
# takes gettext-runtime's config.h), and only intl/ is installed.
build() {
    # Without the driver's -lintl, with which configure finds gettext() in
    # what it takes to be the C library, and builds no libintl; and the
    # included libintl even where one is installed already.
    unset LDFLAGS
    cd gettext-runtime
    ./configure --prefix=/usr --disable-static --with-included-libintl
    make
}

package() {
    make -C gettext-runtime/intl DESTDIR="$DESTDIR" install
    # intl/ installs nothing where configure chose another libintl.
    [[ -e $DESTDIR/usr/lib/libintl.so.8 ]] || { echo "libintl.so.8 was not installed" >&2; return 1; }
}
