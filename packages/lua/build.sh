prepare() {
    # Upstream ships no pkg-config file.
    cat > lua.pc << "EOF"
V=5.4
R=5.4.8

prefix=/usr
INSTALL_BIN=${prefix}/bin
INSTALL_INC=${prefix}/include
INSTALL_LIB=${prefix}/lib
INSTALL_MAN=${prefix}/share/man/man1
INSTALL_LMOD=${prefix}/share/lua/${V}
INSTALL_CMOD=${prefix}/lib/lua/${V}
exec_prefix=${prefix}
libdir=${exec_prefix}/lib
includedir=${prefix}/include

Name: Lua
Description: An Extensible Extension Language
Version: ${R}
Requires:
Libs: -L${libdir} -llua -lm -ldl
Cflags: -I${includedir}
EOF

    # Build a shared liblua and look for modules under /usr.
    patch -Np1 -i "$SOURCES/lua-5.4.8-shared_library-1.patch"
}

build() {
    make CC="$CC -std=gnu99" AR="$AR rcu" RANLIB="$RANLIB" linux
}

package() {
    # The Makefile has no DESTDIR: the installation directories are given
    # with the staging directory in front. The paths compiled into lua
    # (LUA_ROOT, set to /usr/ by the patch) are not affected.
    make INSTALL_TOP="$DESTDIR/usr" \
        INSTALL_DATA="cp -d" \
        INSTALL_MAN="$DESTDIR/usr/share/man/man1" \
        TO_LIB="liblua.so liblua.so.5.4 liblua.so.5.4.8" \
        install

    install -v -m644 -D lua.pc "$DESTDIR/usr/lib/pkgconfig/lua.pc"
}
