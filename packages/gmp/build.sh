prepare() {
    # The configure probe calls g with arguments. In C23 g() takes none.
    sed -i '/long long t1;/,+1s/void g()/void g(int i, ...)/' configure
}

build() {
    # CONFIG_SITE pins a generic aarch64 host, so GMP selects arm64 code
    # for the ARMv8-A baseline without probing the build CPU.
    ./configure --prefix=/usr \
        --enable-cxx \
        --disable-static \
        --docdir=/usr/share/doc/gmp-6.3.0
    make
}

package() {
    make DESTDIR="$DESTDIR" install
}
