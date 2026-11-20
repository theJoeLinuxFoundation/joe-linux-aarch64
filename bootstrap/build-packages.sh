#!/bin/bash
# Builds every recipe, in the order given by bootstrap/order.py, with
# `dave build`, publishing the
# packages to build/repo and installing each one into the build root so the
# next recipe builds against it. This is where the temporary tools of stages 1
# and 2 are replaced, one by one, by real joe Linux packages.
#
#   build-packages.sh [PACKAGE...]    build only the named packages (in order)
#
# Resumable: a package whose file already exists in the repository is skipped.
#
# Every file is sealed with the code-signing key. A program its recipe does
# not declare is sealed as `undeclared`: it has no authority of its own (see
# packages/linux/joe-lsm/joe.c). `dave repo audit build/repo` lists the
# privileged programs that still need a declaration.
set -euo pipefail

top=$(cd "$(dirname "$0")/.." && pwd)
root=$top/build/bootstrap/root
repo=$top/build/repo
keys=$top/build/keys
# dave for this machine, managing aarch64 systems: it builds the packages.
dave=$top/dave/zig-out/bin/dave
# dave for aarch64: the one the dave package ships.
dave_target=$top/build/dave-aarch64/bin/dave
arch=aarch64

if [[ $(id -u) -ne 0 ]]; then
    [[ -e $top/build/bootstrap/done/cleanup ]] || { echo "run stage1.sh and stage2.sh first" >&2; exit 1; }
    "$top/bootstrap/order.py" "$@" >/dev/null
    (cd "$top/dave" && zig build -Doptimize=ReleaseSafe -Darch=$arch)
    (cd "$top/dave" && zig build -Doptimize=ReleaseSafe -Dtarget=$arch-linux-none --prefix "$top/build/dave-$arch")
    mkdir -p "$keys" "$repo"
    [[ -e $keys/joe.key ]] || "$dave" key generate "$keys/joe" >/dev/null
    # The code-signing key seals every file of every package; its public half
    # is compiled into the kernel's security module.
    [[ -e $keys/joe-code.key ]] || "$dave" key generate-code "$keys/joe-code" >/dev/null
    {
        echo "/* Generated from the code-signing public key by bootstrap/build-packages.sh. */"
        echo "static const u8 joe_keys[][65] = {"
        printf '\t{ %s },\n' "$(sed 's/../0x&, /g; s/, $//' "$keys/joe-code.pub")"
        echo "};"
    } > "$top/packages/linux/joe-lsm/joe_keys.h"
    # The dave recipe packages the aarch64 binary just built, its services
    # in system/, and its manual page and shell completions from dave/share/.
    if [[ -d $top/packages/dave ]]; then
        rm -rf "$top/packages/dave/files"
        mkdir -p "$top/packages/dave/files"
        cp "$dave_target" "$top/packages/dave/files/"
        cp -r "$top"/system/. "$top/packages/dave/files/" 2>/dev/null || true
        cp "$top"/dave/share/* "$top/packages/dave/files/"
    fi
    # dynamod (the init system) is cross-built here too: its PID 1 by Zig,
    # the rest by the bootstrap's Rust cross compiler for bionic, linked by
    # the cross toolchain against the build root's C library. The source is
    # the dynamod checkout named by JOE_DYNAMOD (default: ../dynamod, beside
    # this repository; branch aarch64-bionic of theJoeLinuxFoundation/dynamod).
    # What a console server needs: the service manager, its command, the log
    # daemon, and the tmpfiles.d and sysusers.d tools; not the desktop's
    # D-Bus services.
    rust=$top/build/bootstrap/rust
    if [[ -d $top/packages/dynamod && ! -x $rust/bin/cargo ]]; then
        echo "warning: no Rust cross compiler yet (bootstrap/stage1.sh): dynamod cannot be built" >&2
    elif [[ -d $top/packages/dynamod ]]; then
        dynamod=${JOE_DYNAMOD:-$(cd "$top/.." && pwd)/dynamod}
        cross=$root/usr/lib/joe-cross
        (cd "$dynamod/zig" && zig build -Doptimize=ReleaseSafe -Dtarget=$arch-linux-none --prefix "$top/build/dynamod-$arch")
        (cd "$dynamod/rust" &&
            PATH=$rust/bin:$PATH RUSTC=$rust/bin/rustc \
            CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER=$cross/bin/clang \
            CC_aarch64_linux_android=$cross/bin/clang AR_aarch64_linux_android=$cross/bin/llvm-ar \
            CARGO_TARGET_DIR=$top/build/dynamod-target \
            "$rust/bin/cargo" build --release --locked --target aarch64-linux-android \
                -p dynamod-svmgr -p dynamodctl -p dynamod-logd -p dynamod-tmpfiles -p dynamod-sysusers)
        files=$top/packages/dynamod/files
        rm -rf "$files"
        mkdir -p "$files/services" "$files/supervisors"
        cp "$top/build/dynamod-$arch/bin/dynamod-init" "$files/"
        for b in dynamod-svmgr dynamodctl dynamod-logd dynamod-tmpfiles dynamod-sysusers; do
            cp "$top/build/dynamod-target/aarch64-linux-android/release/$b" "$files/"
        done
        cp "$dynamod/config/supervisors/root.toml" "$dynamod/config/supervisors/early-boot.toml" "$files/supervisors/"
        cp "$dynamod/config/services/sysusers.toml" "$dynamod/config/services/tmpfiles-setup.toml" \
            "$dynamod/config/services/machine-id.toml" "$files/services/"
    fi
    # Installing into the build root runs triggers in a chroot, which needs the
    # privileges a user namespace provides.
    exec unshare --map-root-user "$0" "$@"
fi

# The build root is itself managed by dave, using the repository being built.
mkdir -p "$root/etc/dave/keys"
cp "$keys/joe.pub" "$root/etc/dave/keys/"
cat > "$root/etc/dave/repos.zon" <<EOT
.{ .repos = .{ .{ .name = "joe", .url = "$repo" } } }
EOT

field() { # field <recipe dir> <name>: a top-level value from package.zon
    sed -n "s/^ *\.$2 = \"\{0,1\}\([^\",]*\)\"\{0,1\},.*/\1/p" "$1/package.zon" | head -n 1
}

while read -r name flag; do
    [[ -z $name ]] && continue
    recipe=$top/packages/$name
    [[ -e $recipe/package.zon ]] || { echo "no recipe for $name" >&2; exit 1; }
    version=$(field "$recipe" version)-r$(field "$recipe" release)
    file=$repo/$name-$version-$arch.dave

    if [[ ! -e $file ]]; then
        echo "==> building $name $version"
        started=$SECONDS
        if ! "$dave" build "$recipe" --buildroot "$root" --sources "$top/build/src" \
            --work "$top/build/work" --out "$repo" --code-key "$keys/joe-code.key" \
            >/dev/null; then
            echo "--- last lines of $top/build/work/$name/build.log" >&2
            tail -n 40 "$top/build/work/$name/build.log" >&2 || true
            exit 1
        fi
        echo "    built in $((SECONDS - started))s, $(du -h "$file" | cut -f1)"
        "$dave" repo index "$repo" --key "$keys/joe.key" >/dev/null
    fi

    [[ $flag == build-only ]] && continue
    # Not grep -q: it would exit at the first match, and under pipefail the
    # list command's SIGPIPE would count as "not installed".
    if ! "$dave" --root "$root" list | grep -x "$name $version\( .*\)\{0,1\}" >/dev/null; then
        echo "    installing $name $version into the build root"
        "$dave" --root "$root" --overwrite install "$name=$version" >/dev/null
    fi
done < <("$top/bootstrap/order.py" "$@")

echo "all packages built: $repo"
