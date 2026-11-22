# joe Linux releases are named J<X>-<Y>-<Z>[-<stage>] (README.md, "Releases"):
#
#   X      the system revision: this package's version, without its stage
#   Y      the kernel's version (packages/linux)
#   Z      dave's version (packages/dave and dave/src/main.zig)
#   stage  alpha1, beta1, rc1 ...; nothing for a final release
#
# Y and Z are written here, so this recipe changes (and its .release is
# bumped) whenever the kernel's or dave's version does. Nothing checks them
# against the running kernel and dave yet (joe Linux's tests/vm/live.tomlx
# does), so keep them in step by hand.

# Prints the release's name; build machine scripts call it as well.
release_name() {
    local kernel=7.3.1 dave=0.3.0
    local revision=${PKG_VERSION%%[a-z]*}
    local stage=${PKG_VERSION#"$revision"}
    printf 'J%s-%s-%s%s\n' "$revision" "$kernel" "$dave" "${stage:+-$stage}"
}

package() {
    local name
    name=$(release_name)
    install -d "$DESTDIR/usr/lib" "$DESTDIR/etc"
    cat > "$DESTDIR/usr/lib/os-release" <<EOT
NAME="joe Linux ARM"
ID=joe
VARIANT="64-bit Arm servers"
VARIANT_ID=arm
PRETTY_NAME="joe Linux ARM $name"
VERSION="$name"
VERSION_ID=$PKG_VERSION
BUILD_ID=$PKG_RELEASE
EOT
    ln -s ../usr/lib/os-release "$DESTDIR/etc/os-release"
    printf 'joe Linux ARM %s \\n \\l\n\n' "$name" > "$DESTDIR/etc/issue"
}
