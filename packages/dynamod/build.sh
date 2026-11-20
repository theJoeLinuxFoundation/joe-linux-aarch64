# dynamod is cross-built on the build machine, like dave: its PID 1 by Zig
# (static, no libc), the rest by the Rust cross compiler of the bootstrap
# for aarch64-linux-android, against bionic. bootstrap/build-packages.sh
# places the programs and dynamod's own service definitions in files/.
NOSTRIP=1

package() {
    local f=/recipe/files
    install -Dm755 "$f/dynamod-init" "$DESTDIR/usr/sbin/dynamod-init"
    # The kernel runs /sbin/init when the command line names no other.
    ln -s dynamod-init "$DESTDIR/usr/sbin/init"
    install -Dm755 "$f/dynamod-svmgr" "$DESTDIR/usr/lib/dynamod/dynamod-svmgr"
    install -Dm755 "$f/dynamod-logd" "$DESTDIR/usr/lib/dynamod/dynamod-logd"
    install -Dm755 "$f/dynamodctl" "$DESTDIR/usr/bin/dynamodctl"
    install -Dm755 "$f/dynamod-tmpfiles" "$DESTDIR/usr/bin/dynamod-tmpfiles"
    install -Dm755 "$f/dynamod-sysusers" "$DESTDIR/usr/bin/dynamod-sysusers"

    # The names people and packages call: dynamodctl answers to each.
    local name
    for name in reboot poweroff halt shutdown; do
        ln -s ../bin/dynamodctl "$DESTDIR/usr/sbin/$name"
    done
    ln -s dynamodctl "$DESTDIR/usr/bin/systemctl"
    # Packages' triggers run these by systemd's names.
    ln -s dynamod-tmpfiles "$DESTDIR/usr/bin/systemd-tmpfiles"
    ln -s dynamod-sysusers "$DESTDIR/usr/bin/systemd-sysusers"

    # The supervisor tree, and the services of dynamod's own tools. The
    # administrator's directories, /etc/dynamod/{services,supervisors,
    # enabled,disabled}, start empty.
    install -d "$DESTDIR/usr/lib/dynamod/services" "$DESTDIR/usr/lib/dynamod/supervisors"
    install -m644 "$f"/supervisors/*.toml "$DESTDIR/usr/lib/dynamod/supervisors/"
    install -m644 "$f"/services/*.toml "$DESTDIR/usr/lib/dynamod/services/"
    install -d "$DESTDIR/etc/dynamod"/{services,supervisors,enabled,disabled}

    # What these find when a package has changed: the accounts and the files
    # under /var that newly installed packages declare. Packages have no
    # install scripts; dave runs these once per transaction.
    install -d "$DESTDIR/usr/lib/dave/triggers"
    cat > "$DESTDIR/usr/lib/dave/triggers/11-sysusers.zon" <<'EOT'
.{
    .name = "system accounts",
    .paths = .{"usr/lib/sysusers.d/"},
    .exec = .{"/usr/bin/systemd-sysusers"},
}
EOT
    cat > "$DESTDIR/usr/lib/dave/triggers/12-tmpfiles.zon" <<'EOT'
.{
    .name = "declared files and directories",
    // Repeated at every boot by the tmpfiles-setup service, and unable to
    // set owners where an image is assembled in a user namespace.
    .optional = true,
    .paths = .{"usr/lib/tmpfiles.d/"},
    .exec = .{ "/usr/bin/systemd-tmpfiles", "--create", "--exclude-prefix=/dev", "--exclude-prefix=/proc", "--exclude-prefix=/sys", "--exclude-prefix=/run" },
}
EOT
}
