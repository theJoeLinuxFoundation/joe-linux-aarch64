prepare() {
    # bionic's pthread functions live in libc. Its compatibility libpthread
    # otherwise triggers a weak-symbol check for the absent pthread_cancel.
    sed -i 's/if test \$gl_pthread_in_glibc = yes; then/if test "$host_os" = linux-android || test $gl_pthread_in_glibc = yes; then/' configure
}

build() {
    ./configure --prefix=/usr --sysconfdir=/etc --disable-static
    make
}

package() {
    make DESTDIR="$DESTDIR" install
}
