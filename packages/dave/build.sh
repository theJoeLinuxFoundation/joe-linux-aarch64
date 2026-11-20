# dave is a static binary with no libc, cross-built by Zig on the build
# machine for aarch64, because joe does not package a Zig compiler yet.
# bootstrap/build-packages.sh places the binary, the dynamod services from
# system/, and the manual page and shell completions from dave/share/ in
# this recipe's files/ directory before the build.
NOSTRIP=1

package() {
    local services="$DESTDIR/usr/lib/dynamod/services" s
    install -Dm755 /recipe/files/dave "$DESTDIR/usr/bin/dave"
    # The services are on by default (they declare nothing else), so
    # shipping them is enabling them: there are no install scripts.
    for s in dave-seal dave-finalize dave-boot-check dave-boot-watchdog; do
        install -Dm644 "/recipe/files/$s.toml" "$services/$s.toml"
    done

    install -d "$DESTDIR/usr/lib/tmpfiles.d"
    echo 'd /var/cache/dave 0755 root root -' > "$DESTDIR/usr/lib/tmpfiles.d/dave.conf"

    # Each shell finds these when it completes `dave`; they ask dave itself.
    local share="$DESTDIR/usr/share"
    install -Dm644 /recipe/files/dave.8 "$share/man/man8/dave.8"
    install -Dm644 /recipe/files/completion.bash "$share/bash-completion/completions/dave"
    install -Dm644 /recipe/files/completion.zsh "$share/zsh/site-functions/_dave"
    install -Dm644 /recipe/files/completion.fish "$share/fish/vendor_completions.d/dave.fish"
}
