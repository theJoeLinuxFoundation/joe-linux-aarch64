prepare() {
    patch -Np1 -i /recipe/bionic-shutdown.patch
    # Comment out the rest of util/meson.build from the udev rule on. That
    # drops the udev rule and the SysV boot script, which are not needed,
    # and with them the whole install helper script, which would otherwise
    # chown fusermount3 and mknod /dev/fuse inside $DESTDIR.
    sed -i '/^udev/,$ s/^/#/' util/meson.build
}

build() {
    mkdir -p build
    cd build
    # No liburing or libnuma for FUSE-over-io-uring. The classic Linux
    # mount supports single- and multithreaded loops. Examples and tests
    # are never installed.
    meson setup --prefix=/usr .. \
        --libdir=lib \
        --buildtype=release \
        -D enable-io-uring=false \
        -D examples=false \
        -D tests=false
    ninja
}

package() {
    cd build
    DESTDIR="$DESTDIR" ninja install

    # fusermount3 mounts on behalf of unprivileged users.
    chmod 4755 "$DESTDIR/usr/bin/fusermount3"

    # With the install helper gone (see prepare) nothing installs a
    # configuration file; this is the book's.
    install -d "$DESTDIR/etc"
    cat > "$DESTDIR/etc/fuse.conf" << "EOF2"
# Set the maximum number of FUSE mounts allowed to non-root users.
# The default is 1000.
#
#mount_max = 1000

# Allow non-root users to specify the 'allow_other' or 'allow_root'
# mount options.
#
#user_allow_other
EOF2
}
