# Not in the book: the newest upstream release, built as doc/install.md
# says.
build() {
    # DEPS=LOCAL: never download a missing dependency; use the system's or
    # the bundled copy. No Redis remote storage (hiredis), no test suite
    # (doctest). The manual and its man page need Asciidoctor. The faster
    # linker it would look for (lld or gold) is not wanted for a package
    # build.
    cmake -B build -G Ninja \
        -D CMAKE_INSTALL_PREFIX=/usr \
        -D CMAKE_INSTALL_SYSCONFDIR=/etc \
        -D CMAKE_BUILD_TYPE=Release \
        -D DEPS=LOCAL \
        -D DEP_FMT=BUNDLED \
        -D REDIS_STORAGE_BACKEND=OFF \
        -D HTTP_STORAGE_BACKEND=ON \
        -D ENABLE_TESTING=OFF \
        -D ENABLE_BENCHMARKS=OFF \
        -D ENABLE_DOCUMENTATION=OFF \
        -D USE_FASTER_LINKER=OFF \
        -D STATIC_LINK=OFF
    ninja -C build
}

package() {
    DESTDIR="$DESTDIR" cmake --install build
}
