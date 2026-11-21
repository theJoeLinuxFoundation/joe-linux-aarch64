# Not in the book: the newest upstream release, built with CMake as its
# README-compiling.md says.
prepare() {
    # A bionic client stops its network thread through the run flag and
    # wake socket, including during startup and reconnect backoff.
    patch -Np1 -i /recipe/bionic-loop-stop.patch
}

build() {
    # Keep the upstream TLS, built-in WebSockets, bridge and persistence
    # options. The HTTP API needs libmicrohttpd, and the dashboard needs
    # Tailwind. Dynamod runs the broker in the foreground.
    # Off: the example plugins, tests, SRV lookups (c-ares, off by
    # default), getaddrinfo_a and tcp-wrappers. The manual pages ship
    # ready-made.
    cmake -B build -G Ninja \
        -D CMAKE_BUILD_TYPE=Release \
        -D CMAKE_INSTALL_PREFIX=/usr \
        -D CMAKE_INSTALL_LIBDIR=lib \
        -D CMAKE_INSTALL_SYSCONFDIR=/etc \
        -D WITH_BUNDLED_DEPS=ON \
        -D WITH_TLS=ON \
        -D WITH_TLS_PSK=ON \
        -D WITH_WEBSOCKETS=ON \
        -D WITH_WEBSOCKETS_BUILTIN=ON \
        -D WITH_SYSTEMD=OFF \
        -D WITH_HTTP_API=OFF \
        -D HTTP_API_DIR= \
        -D WITH_CTRL_SHELL=ON \
        -D WITH_PLUGIN_PERSIST_SQLITE=ON \
        -D WITH_PLUGIN_EXAMPLES=OFF \
        -D WITH_SRV=OFF \
        -D WITH_ADNS=OFF \
        -D USE_LIBWRAP=OFF \
        -D WITH_DLT=OFF \
        -D WITH_DOCS=OFF \
        -D WITH_TESTS=OFF \
        -D WITH_STATIC_LIBRARIES=OFF
    cmake --build build
}

package() {
    DESTDIR="$DESTDIR" cmake --install build
    # Install the release manual pages. Regenerating them with xsltproc
    # requires the DocBook stylesheets, which the build root does not have.
    local section
    for section in 1 3 5 7 8; do
        install -Dm644 -t "$DESTDIR/usr/share/man/man$section" man/*."$section"
    done

    # make install puts upstream's annotated configuration, every option
    # commented out, in /etc/mosquitto as mosquitto.conf.example; the
    # unit reads mosquitto.conf, so it is installed under that name too.
    # Without a listener the broker serves localhost only.
    install -m644 mosquitto.conf "$DESTDIR/etc/mosquitto/mosquitto.conf"

    # The account the broker runs as. Its home holds the persistence
    # database when persistence_location points there.
    install -d "$DESTDIR/usr/lib/sysusers.d" "$DESTDIR/usr/lib/tmpfiles.d"
    cat > "$DESTDIR/usr/lib/sysusers.d/mosquitto.conf" << "EOT"
g mosquitto 39
u mosquitto 39:39 "Mosquitto MQTT broker" /var/lib/mosquitto /usr/bin/false
EOT
    cat > "$DESTDIR/usr/lib/tmpfiles.d/mosquitto.conf" << "EOT"
d /var/lib/mosquitto 0700 mosquitto mosquitto -
d /run/mosquitto 0755 mosquitto mosquitto -
d /var/log/mosquitto 0755 mosquitto mosquitto -
EOT

    install -d "$DESTDIR/usr/lib/dynamod/services"
    install -m644 /recipe/*.toml "$DESTDIR/usr/lib/dynamod/services/"
}
