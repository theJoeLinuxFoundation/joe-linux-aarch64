# Not in the book: the newest stable release (the even-numbered branch),
# configured as nginx.org's own packages are (nginx -V of those packages,
# and https://nginx.org/en/docs/configure.html).
prepare() {
    # The generated QUIC helper includes stdint.h before nginx requests
    # the GNU cpu_set_t declaration. Load the nginx feature macros first.
    sed -i '/^#include <stddef.h>/i#include <ngx_config.h>' src/event/quic/ngx_event_quic_bpf_code.c
    # Bionic's epoll masks contain casts, which #if cannot evaluate.
    # Set the kernel event mask in each branch; clang folds the constants.
    sed -i '/^#if (NGX_READ_EVENT != EPOLLIN|EPOLLRDHUP)/,/^#endif/ { /^#/d; }
            /^#if (NGX_WRITE_EVENT != EPOLLOUT)/,/^#endif/ { /^#/d; }' src/event/modules/ngx_epoll_module.c
}

build() {
    # The paths of nginx.org's packages, except the prefix: it is
    # /usr/share/nginx, so that the default page and every relative path in
    # nginx.conf ("root html;") resolve there rather than under /etc.
    # Modules: those of nginx.org's packages, including HTTP/2 and HTTP/3
    # (QUIC through OpenSSL). Left out, as there: the XSLT, image filter,
    # GeoIP and Perl modules.
    ./configure --with-cc="$CC" \
        --prefix=/usr/share/nginx \
        --sbin-path=/usr/sbin/nginx \
        --modules-path=/usr/lib/nginx/modules \
        --conf-path=/etc/nginx/nginx.conf \
        --error-log-path=/var/log/nginx/error.log \
        --http-log-path=/var/log/nginx/access.log \
        --pid-path=/run/nginx.pid \
        --lock-path=/run/nginx.lock \
        --http-client-body-temp-path=/var/cache/nginx/client_temp \
        --http-proxy-temp-path=/var/cache/nginx/proxy_temp \
        --http-fastcgi-temp-path=/var/cache/nginx/fastcgi_temp \
        --http-uwsgi-temp-path=/var/cache/nginx/uwsgi_temp \
        --http-scgi-temp-path=/var/cache/nginx/scgi_temp \
        --user=nginx \
        --group=nginx \
        --with-compat \
        --with-file-aio \
        --with-threads \
        --with-pcre \
        --with-pcre-jit \
        --with-http_addition_module \
        --with-http_auth_request_module \
        --with-http_dav_module \
        --with-http_flv_module \
        --with-http_gunzip_module \
        --with-http_gzip_static_module \
        --with-http_mp4_module \
        --with-http_random_index_module \
        --with-http_realip_module \
        --with-http_secure_link_module \
        --with-http_slice_module \
        --with-http_ssl_module \
        --with-http_stub_status_module \
        --with-http_sub_module \
        --with-http_v2_module \
        --with-http_v3_module \
        --with-mail \
        --with-mail_ssl_module \
        --with-stream \
        --with-stream_realip_module \
        --with-stream_ssl_module \
        --with-stream_ssl_preread_module
    make
}

package() {
    make DESTDIR="$DESTDIR" install
    install -Dm644 objs/nginx.8 "$DESTDIR/usr/share/man/man8/nginx.8"

    # The account the workers run as (the master stays root).
    install -d "$DESTDIR/usr/lib/sysusers.d" "$DESTDIR/usr/lib/tmpfiles.d"
    cat > "$DESTDIR/usr/lib/sysusers.d/nginx.conf" << "EOF"
g nginx 44
u nginx 44:44 "nginx web server" /var/cache/nginx /usr/bin/false
EOF
    # The logs (opened by the master) and the temporary files of the
    # workers, whose subdirectories nginx makes itself. /var is not
    # packaged.
    cat > "$DESTDIR/usr/lib/tmpfiles.d/nginx.conf" << "EOF"
d /var/log/nginx 0755 root root -
d /var/cache/nginx 0700 nginx nginx -
EOF

    install -d "$DESTDIR/usr/lib/dynamod/services"
    install -m644 /recipe/*.toml "$DESTDIR/usr/lib/dynamod/services/"
}
