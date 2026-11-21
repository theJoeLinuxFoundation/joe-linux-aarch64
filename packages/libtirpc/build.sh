prepare() {
    # The 1.3.7 version node lists these even when AUTH_DES and GSS are
    # disabled. Their implementations are omitted, so lld rejects the map.
    sed -i -e '/^[[:space:]]*authdes_getucred;$/d' \
        -e '/^[[:space:]]*rpc_gss_getcred;$/d' src/libtirpc.map.in
}

build() {
    # --disable-gssapi: MIT Kerberos is not part of joe Linux.
    ./configure --prefix=/usr \
        --sysconfdir=/etc \
        --disable-static \
        --disable-authdes \
        --disable-gssapi
    make
}

package() {
    make DESTDIR="$DESTDIR" install
}
