prepare() {
    sed -i '1s/python$/python3/' event_rpcgen.py
}

build() {
    ./configure --prefix=/usr --disable-static
    make
}

package() {
    make DESTDIR="$DESTDIR" install
}
