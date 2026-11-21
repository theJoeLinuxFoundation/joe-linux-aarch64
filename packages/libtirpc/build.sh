prepare() {
    # The 1.3.7 version node lists these even when AUTH_DES and GSS are
    # disabled. Their implementations are omitted, so lld rejects the map.
    sed -i -e '/^[[:space:]]*authdes_getucred;$/d' \
        -e '/^[[:space:]]*rpc_gss_getcred;$/d' src/libtirpc.map.in
}

build() {
    # --disable-gssapi: MIT Kerberos is not part of joe Linux.
    # Bionic does not supply the RPC database functions. The bundled
    # getrpcent.c uses K&R definitions, which are accepted through C17.
    CFLAGS="${CFLAGS:--O2} -std=gnu17" ./configure --prefix=/usr \
        --sysconfdir=/etc \
        --enable-rpcdb \
        --disable-static \
        --disable-authdes \
        --disable-gssapi
    make
}

package() {
    make DESTDIR="$DESTDIR" install
    install -Dm644 /recipe/rpc "$DESTDIR/etc/rpc"
}
