prepare() {
    # egrep and fgrep print an obsolescence warning that breaks the test
    # suites of some other packages.
    sed -i "s/echo/#echo/" src/egrep.sh
}

build() {
    # pcre2 is not part of the system.
    ./configure --prefix=/usr --disable-perl-regexp
    make
}

package() {
    make DESTDIR="$DESTDIR" install
}
