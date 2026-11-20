prepare() {
    # Never choose lib64 for the packages cmake configures.
    sed -i '/"lib64"/s/64//' Modules/GNUInstallDirs.cmake
    # Compiled with __ANDROID__ (bionic), cmake names its system "Android",
    # as Termux, an Android app, needs; joe's is Linux, which uname says.
    sed -i -e '/^#elif defined(__ANDROID__)$/{N;/return "Android";/d;}' \
        -e 's/^#if !defined(_WIN32) && !defined(__ANDROID__)$/#if !defined(_WIN32)/' \
        Source/cmSystemTools.cxx
    if grep -q 'return "Android";' Source/cmSystemTools.cxx; then
        echo "cmake: its Android system name is still there" >&2
        return 1
    fi
    # Its libarchive includes, for Android, a header of libarchive's own
    # (contrib/android) that cmake's copy leaves out: it renames the file
    # functions to their *64 forms, which 32-bit Android needs. On a 64-bit
    # system they are the same functions, and the header has nothing to do.
    printf '/* 64-bit: nothing to rename. */\n' >Utilities/cmlibarchive/libarchive/android_lf.h
}

build() {
    # The bundled libraries (curl, libarchive, libuv and the rest): cmake is a
    # build tool in joe Linux ARM and those are not part of the base system.
    # No TLS: nothing joe builds lets cmake download.
    ./bootstrap --prefix=/usr \
        --mandir=/share/man \
        --docdir=/share/doc/cmake-4.4.5 \
        --parallel="$JOBS" \
        -- -DCMAKE_USE_OPENSSL=OFF -DBUILD_TESTING=OFF
    make
}

package() {
    make DESTDIR="$DESTDIR" install
}
