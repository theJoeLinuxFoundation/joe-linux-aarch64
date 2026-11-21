# SSHFS needs GLib and GThread. The reference recipe's second bootstrap
# pass is for GObject Introspection and is unnecessary for these libraries.
build() {
    meson setup build --prefix=/usr --libdir=lib --buildtype=release \
        -D introspection=disabled \
        -D glib_debug=disabled \
        -D man-pages=disabled \
        -D sysprof=disabled \
        -D selinux=disabled \
        -D libmount=enabled \
        -D libelf=disabled \
        -D dtrace=disabled \
        -D systemtap=disabled \
        -D documentation=false \
        -D tests=false \
        -D installed_tests=false
    ninja -C build
}

package() {
    DESTDIR="$DESTDIR" ninja -C build install
    # GSettings schemas and GIO modules are compiled into caches that must
    # follow every change to their directories.
    install -d "$DESTDIR/usr/share/glib-2.0/schemas" "$DESTDIR/usr/lib/gio/modules"
    install -d "$DESTDIR/usr/lib/dave/triggers"
    cat > "$DESTDIR/usr/lib/dave/triggers/30-glib-schemas.zon" <<'EOT'
.{
    .name = "GSettings schema cache",
    .paths = .{"usr/share/glib-2.0/schemas/"},
    .exec = .{ "/usr/bin/glib-compile-schemas", "/usr/share/glib-2.0/schemas" },
}
EOT
    cat > "$DESTDIR/usr/lib/dave/triggers/31-gio-modules.zon" <<'EOT'
.{
    .name = "GIO module cache",
    .paths = .{"usr/lib/gio/modules/"},
    .exec = .{ "/usr/bin/gio-querymodules", "/usr/lib/gio/modules" },
}
EOT
}
