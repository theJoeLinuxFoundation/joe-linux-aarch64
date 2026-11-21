build() {
    make CC="$CC" AR="$AR" BUILD_STATIC=no PREFIX=/usr
}

package() {
    make CC="$CC" AR="$AR" BUILD_STATIC=no PREFIX=/usr DESTDIR="$DESTDIR" install
}
