prepare() {
    # libbsd requires an explicit list of the BSD interfaces it supplies
    # for each libc. bionic already supplies several of them.
    patch -Np1 -i /recipe/bionic-abi.patch
    autoreconf -fi
}

# Not in the book: the newest upstream release, built as its README says.
build() {
    ./configure --prefix=/usr \
        --disable-static
    make
}

package() {
    make DESTDIR="$DESTDIR" install
}
