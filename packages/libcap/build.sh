prepare() {
    # Do not install the static libraries.
    sed -i '/install -m.*STA/d' libcap/Makefile
}

# lib=lib: libraries go in /usr/lib, not /usr/lib64.
# GOLANG=no: never build the Go bindings, whatever the build root contains.
# Make.Rules sets gcc and binutils' tools with :=, which only the command
# line overrides; joe's are LLVM's (the driver's), also for the helper that
# runs during the build (BUILD_CC).
make_args=(prefix=/usr lib=lib GOLANG=no CC="$CC" BUILD_CC="$CC" AR="$AR"
    RANLIB="$RANLIB" OBJCOPY="$OBJCOPY")

build() {
    make "${make_args[@]}"
}

package() {
    # RAISE_SETFCAP=no (the default, stated here on purpose): do not run setcap
    # on the installed setcap binary.
    make "${make_args[@]}" RAISE_SETFCAP=no DESTDIR="$DESTDIR" install
}
