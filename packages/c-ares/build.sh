prepare() {
    # Android apps get DNS settings from Java's ConnectivityManager. joe
    # reads resolv.conf and watches it with inotify. Keep the bionic header
    # workarounds in ares_setup.h.
    sed -Ei 's/^(#(if|elif)) defined\(ANDROID\) \|\| defined\(__ANDROID__\)$/\1 0/' \
        include/ares.h src/lib/ares_android.{c,h} src/lib/ares_{init,library_init,sysconfig,sysconfig_files}.c
    sed -i 's/^#if defined(__ANDROID__) \&\& defined(CARES_THREADS)$/#if 0/' \
        src/lib/event/ares_event_configchg.c
}

build() {
    mkdir build
    cd build
    # The book's command, plus CMAKE_INSTALL_LIBDIR so that nothing can pick
    # lib64, and no test programs.
    cmake -D CMAKE_INSTALL_PREFIX=/usr \
        -D CMAKE_INSTALL_LIBDIR=lib \
        -D CMAKE_BUILD_TYPE=Release \
        -D CARES_BUILD_TESTS=OFF \
        ..
    make
}

package() {
    cd build
    make DESTDIR="$DESTDIR" install
}
