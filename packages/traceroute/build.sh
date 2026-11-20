# Following the book's Traceroute page (basicnet/traceroute).
# Its rules name gcc, and gcc's ar and ranlib: LLVM's are given instead,
# with the flags the rules give gcc (for another compiler they give -O).
make_args=(CC="$CC" DEPEND="$CC -MM -MG" AR="$AR" RANLIB="$RANLIB" CFLAGS="-O2 -Wall")

prepare() {
    # flowlabel.h is traceroute's copy of the kernel's <linux/in6.h> flow
    # label definitions, for glibc, whose <netinet/in.h> conflicts with that
    # header. bionic's <netinet/in.h> includes <linux/in6.h> itself, so the
    # copy would define them twice.
    : > traceroute/flowlabel.h
}

build() {
    make "${make_args[@]}"
}

package() {
    make "${make_args[@]}" prefix=/usr DESTDIR="$DESTDIR" install
    ln -sfv traceroute "$DESTDIR/usr/bin/traceroute6"
    ln -sfv traceroute.8 "$DESTDIR/usr/share/man/man8/traceroute6.8"
    # The book's "rm /usr/share/man/man1/traceroute.1" removes the page of
    # inetutils' traceroute from the system; nothing here installs one.
}
