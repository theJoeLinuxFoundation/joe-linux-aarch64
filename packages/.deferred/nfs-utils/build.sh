prepare() {
    # config.h requests the GNU declaration of unshare before sched.h.
    sed -i '/^#include "config.h"$/d; 1i#include "config.h"' support/misc/workqueue.c
}

build() {
    # The book builds without NFSv4 and GSS. NFSv4 is built here: everything
    # it needs is packaged (libevent, SQLite for nfsdcld, keyutils for
    # nfsidmap). GSS stays off because libtirpc is built without GSS-API.
    # Also stated:
    # - --disable-sbin-override: mount.nfs would otherwise go to /sbin,
    #   which belongs to joe-filesystem as a link to usr/sbin;
    # - dynamod runs the foreground daemons and starts the kernel server;
    # - the user rpc.statd runs as when /var/lib/nfs/sm belongs to nobody
    #   (configure would otherwise look in the build machine's /etc/passwd);
    # - no LDAP (OpenLDAP is not packaged), no blkmapd (pNFS block layout).
    ./configure --prefix=/usr \
        --sysconfdir=/etc \
        --sbindir=/usr/sbin \
        --disable-sbin-override \
        --without-systemd \
        --with-statduser=nobody \
        --enable-nfsv4 \
        --enable-nfsdcld \
        --disable-gss \
        --disable-blkmapd \
        --disable-ldap \
        --enable-caps
    make
}

package() {
    make DESTDIR="$DESTDIR" install
    # The book's chmod: the set-uid mount.nfs is otherwise unreadable.
    chmod u+w,go+r "$DESTDIR/usr/sbin/mount.nfs"
    install -m755 /recipe/start-statd "$DESTDIR/usr/sbin/start-statd"

    # Upstream's configuration files, everything commented out at the
    # defaults.
    install -d "$DESTDIR/etc"
    install -m644 nfs.conf "$DESTDIR/etc/nfs.conf"
    install -m644 utils/mount/nfsmount.conf "$DESTDIR/etc/nfsmount.conf"
    cat > "$DESTDIR/etc/exports" << "EOF"
# Directories exported by the NFS server: see exports(5).
EOF

    # The kernel's NFSv4 client maps user and group names through
    # request-key, which runs nfsidmap; the line is the one nfsidmap(5)
    # gives.
    install -d "$DESTDIR/etc/request-key.d"
    cat > "$DESTDIR/etc/request-key.d/id_resolver.conf" << "EOF"
create	id_resolver	*	*	/usr/sbin/nfsidmap -t 600 %k %d
EOF

    # The state directory, which make install creates under $DESTDIR/var
    # (not packaged). rpc.statd runs as the owner of sm, which the book
    # gives to nobody.
    install -d "$DESTDIR/usr/lib/tmpfiles.d"
    cat > "$DESTDIR/usr/lib/tmpfiles.d/nfs-utils.conf" << "EOF"
d /var/lib/nfs 0755 root root -
f /var/lib/nfs/etab 0644 root root -
f /var/lib/nfs/rmtab 0644 root root -
d /var/lib/nfs/rpc_pipefs 0755 root root -
d /var/lib/nfs/nfsdcld 0700 root root -
d /var/lib/nfs/sm 0700 nobody nogroup -
d /var/lib/nfs/sm.bak 0700 nobody nogroup -
f /var/lib/nfs/state 0600 nobody nogroup -
EOF

    install -d "$DESTDIR/usr/lib/dynamod/services"
    install -m644 /recipe/*.toml "$DESTDIR/usr/lib/dynamod/services/"
}
