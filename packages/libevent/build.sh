prepare() {
    sed -i '1s/python$/python3/' event_rpcgen.py
    # Use upstream's BUILD_WITH_NO_UNDEFINED mode on bionic. It links
    # extra, pthreads and openssl to libevent_core, as the CMake build does.
    sed -i '/test x\$bwin32 .*test x\$cygwin .*test x\$midipix /s/; then/ || test "$host_os" = linux-android; then/' configure
}

build() {
    ./configure --prefix=/usr --disable-static
    make
}

package() {
    make DESTDIR="$DESTDIR" install
}
