# Not in the book: the newest upstream release, built with CMake as its
# README says.
build() {
    # cJSON_Utils (JSON Pointer and Patch) is built too, as most
    # distributions do. Upstream's custom flags add -Werror, which only
    # breaks builds with newer compilers. The project asks for CMake 3.0,
    # which CMake 4 refuses without the policy minimum.
    cmake -B build -G Ninja \
        -D CMAKE_BUILD_TYPE=Release \
        -D CMAKE_INSTALL_PREFIX=/usr \
        -D CMAKE_INSTALL_LIBDIR=lib \
        -D CMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -D ENABLE_CUSTOM_COMPILER_FLAGS=OFF \
        -D ENABLE_CJSON_UTILS=ON \
        -D ENABLE_CJSON_TEST=OFF \
        -D BUILD_SHARED_LIBS=ON
    cmake --build build
}

package() {
    DESTDIR="$DESTDIR" cmake --install build
}
