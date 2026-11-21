prepare() {
    # Configure found the endian macros in endian.h; bytesex.h uses them.
    sed -i '/^#include "compiler.h"/a #include <endian.h>' include/bytesex.h
    # In C23 static_assert is a keyword, so testing for a macro alone
    # selects the fallback with conflicting error attributes under clang.
    sed -i 's/^#ifdef static_assert$/#if defined(static_assert) || __STDC_VERSION__ >= 202311L/' include/nasmlib.h
}

build() {
    ./configure --prefix=/usr
    make
}

package() {
    make DESTDIR="$DESTDIR" install
}
