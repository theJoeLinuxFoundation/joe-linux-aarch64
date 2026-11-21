prepare() {
    # poll.h already declares the poll interfaces. bits/poll.h is private
    # to glibc and does not exist in bionic.
    sed -i '/#include <bits\/poll.h>/d' src/rpcb_svc_com.c
    # /etc/services (iana-etc) names port 111 sunrpc, not rpcbind.
    sed -i "/servname/s:rpcbind:sunrpc:" src/rpcbind.c
}

build() {
    # Bind the RPC sockets directly. Warm starts preserve the registrations.
    ./configure --prefix=/usr \
        --bindir=/usr/sbin \
        --enable-warmstarts \
        --with-rpcuser=rpc \
        --without-systemdsystemunitdir
    make
}

package() {
    make DESTDIR="$DESTDIR" install

    # The account the book creates (groupadd -g 28, useradd -u 28). rpcbind
    # makes its warm-start directory, /run/rpcbind, itself.
    install -d "$DESTDIR/usr/lib/sysusers.d"
    cat > "$DESTDIR/usr/lib/sysusers.d/rpcbind.conf" << "EOF"
g rpc 28
u rpc 28:28 "RPC Bind Daemon Owner" /dev/null /usr/bin/false
EOF

    install -d "$DESTDIR/usr/lib/dynamod/services"
    install -m644 /recipe/*.toml "$DESTDIR/usr/lib/dynamod/services/"
}
