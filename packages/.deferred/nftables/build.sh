# Not in the book: the newest upstream release, built as its INSTALL says.
prepare() {
    # Bionic exposes the kernel ipv6hdr and TCP_FLAG_* through its network
    # headers. The private nftables flags describe a byte, while the kernel
    # flags describe a network-order word. Keep the two definitions distinct.
    sed -i 's/\<ipv6hdr\>/nft_ipv6hdr/g; s/\<TCP_FLAG_/NFT_TCP_FLAG_/g' include/headers.h src/proto.c
}

build() {
    # The interactive mode (nft -i) uses readline: upstream's default,
    # libedit, is not packaged. JSON input and output use jansson. No
    # iptables-nft translation (libxtables) and no Python module (py/ is a
    # separate setuptools project). The manual pages ship ready-made in the
    # tarball, so asciidoc is not needed.
    #
    # The optional dynamod service loads the site's main.nft atomically.
    ./configure --prefix=/usr \
        --sysconfdir=/etc \
        --disable-static \
        --with-cli=readline \
        --with-json \
        --without-xtables \
        --without-unitdir
    make
}

package() {
    make DESTDIR="$DESTDIR" install
    # Supply the upstream starting point without installing a site policy.
    install -d "$DESTDIR/etc/nftables/rules"
    install -Dm644 files/nftables/main.nft "$DESTDIR/usr/share/nftables/main.nft.example"

    install -d "$DESTDIR/usr/lib/dynamod/services"
    install -m644 /recipe/*.toml "$DESTDIR/usr/lib/dynamod/services/"
}
