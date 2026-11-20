prepare() {
    # Do not install the static libraries.
    sed -i '/install -m.*STA/d' libcap/Makefile
}

# lib=lib: libraries go in /usr/lib, not /usr/lib64.
# GOLANG=no: never build the Go bindings, whatever the build root contains.
build() {
    make prefix=/usr lib=lib GOLANG=no
}

package() {
    # RAISE_SETFCAP=no (the default, stated here on purpose): do not run setcap
    # on the installed setcap binary.
    make prefix=/usr lib=lib GOLANG=no RAISE_SETFCAP=no DESTDIR="$DESTDIR" install
}
