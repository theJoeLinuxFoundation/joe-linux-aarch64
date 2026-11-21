prepare() {
    # msgfmt on bionic accepts UTF-8. Preserve pg_config's Norwegian catalog,
    # the one Latin-1 catalog in this release.
    local po=src/bin/pg_config/po/nb.po
    uconv -f ISO-8859-1 -t UTF-8 "$po" | sed 's/charset=iso-8859-1/charset=UTF-8/' > "$po.utf8"
    mv "$po.utf8" "$po"

    # The book's change: the server's socket goes to /run/postgresql.
    sed -e '/DEFAULT_PGSOCKET_DIR/s@/tmp@/run/postgresql@' \
        -i src/include/pg_config_manual.h
}

build() {
    # The book builds with the defaults (ICU, readline, zlib). Added, from
    # its optional dependencies and the packaged libraries: TLS (OpenSSL),
    # the xml type (libxml2), PAM authentication, LZ4 and Zstandard compression,
    # contrib/uuid-ossp (libuuid), translations, and the time zone database
    # of the system rather than a private copy.
    #
    # Left out: PL/Perl, PL/Python and PL/Tcl (they would tie the server to
    # those interpreters), LLVM JIT, LDAP (OpenLDAP is not packaged),
    # io_uring (liburing), OAuth (libcurl), NUMA, SELinux and Bonjour.
    ./configure --prefix=/usr \
        --docdir=/usr/share/doc/postgresql-18.7 \
        --with-system-tzdata=/usr/share/zoneinfo \
        --with-ssl=openssl \
        --with-icu \
        --with-libxml \
        --without-libxslt \
        --with-pam \
        --without-gssapi \
        --with-lz4 \
        --with-zstd \
        --with-uuid=e2fs \
        --enable-nls \
        --with-readline \
        --with-zlib \
        --without-perl \
        --without-python \
        --without-tcl \
        --without-llvm \
        --without-ldap \
        --without-liburing \
        --without-libcurl \
        --without-libnuma \
        --without-selinux \
        --without-bonjour \
        --without-systemd
    make
    # The extensions shipped with PostgreSQL (pgcrypto, hstore,
    # pg_stat_statements, uuid-ossp, ...), which the book leaves optional.
    make -C contrib
    # GSSAPI needs Kerberos. The xml2 extension builds without its XSLT
    # function. Generating the manual pages needs libxslt and DocBook.
}

package() {
    make DESTDIR="$DESTDIR" install
    make -C contrib DESTDIR="$DESTDIR" install

    # The account the book creates (groupadd -g 41, useradd -u 41). Its
    # shell is bash because the administrator works as postgres (su -
    # postgres -c initdb ...).
    #
    # The book keeps the cluster in /srv/pgsql/data. Here it is in /var,
    # which every deployment shares, so that rolling the system back never
    # rolls a database back. No cluster is made: as postgres, run
    #   initdb -D /var/lib/postgres/data
    # before starting the postgresql service.
    install -d "$DESTDIR/usr/lib/sysusers.d" "$DESTDIR/usr/lib/tmpfiles.d"
    cat > "$DESTDIR/usr/lib/sysusers.d/postgresql.conf" << "EOF"
g postgres 41
u postgres 41:41 "PostgreSQL Server" /var/lib/postgres /usr/bin/bash
EOF
    cat > "$DESTDIR/usr/lib/tmpfiles.d/postgresql.conf" << "EOF"
d /var/lib/postgres 0755 postgres postgres -
d /var/lib/postgres/data 0700 postgres postgres -
d /run/postgresql 0755 postgres postgres -
EOF

    install -d "$DESTDIR/usr/lib/dynamod/services"
    install -m644 /recipe/*.toml "$DESTDIR/usr/lib/dynamod/services/"
}
