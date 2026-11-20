# Shared by the bootstrap scripts; sourced, so nothing runs at top level
# except variable definitions (and uname, for the build machine's).
#
# Every source the bootstrap uses is listed in bootstrap/sources with its
# SHA-256. `fetch NAME` makes build/src/NAME exist and match, downloading it
# when needed. A directory named by JOE_SOURCE_CACHE (colon-separated) is
# searched first, so a machine that has built joe Linux before need not
# download the same tarball again.

top=${top:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
src=$top/build/src
hosttools=$top/build/host-tools

# The target: 64-bit Arm, bionic, the newest Android API level whose bionic
# we build (android-17.0.0_r1 is API 37). The API level is what bionic's
# headers use to decide what to declare; clang also reads it from the triple
# (for instance, native ELF TLS needs 29 or later).
JOE_TARGET=aarch64-unknown-linux-android37
JOE_ARCH=aarch64
# The program interpreter of every dynamically linked joe executable: bionic's
# dynamic linker, in place of Android's /system/bin/linker64.
JOE_INTERP=/usr/lib/ld-bionic-$JOE_ARCH.so.1

# The build machine: x86_64, where the build root's aarch64 programs run
# under qemu-user, or aarch64, where they run natively. Its Rust name, for the
# Rust compiler stage 1 builds for it.
JOE_HOST_ARCH=$(uname -m)
JOE_HOST=$JOE_HOST_ARCH-unknown-linux-gnu

# run_target ROOT PROGRAM [ARGS...]: run a program built for joe, in the
# current directory, with ROOT as the file system its dynamic linker and
# libraries come from.
run_target() {
    local root=$1
    shift
    if [[ $JOE_HOST_ARCH == "$JOE_ARCH" ]]; then
        bwrap --bind "$root" / --dev /dev --proc /proc \
            --bind "$PWD" /run/target --chdir /run/target "$@"
    else
        qemu-aarch64 -L "$root" "$@"
    fi
}

# fetch FILE: build/src/FILE, checked against bootstrap/sources, whose lines
# are `FILE SHA256 URL`.
fetch() {
    local file=$1 sum url dir
    read -r _ sum url < <(awk -v f="$file" '$1 == f { print; exit }' "$top/bootstrap/sources")
    [[ -n ${url:-} ]] || { echo "fetch: $file is not in bootstrap/sources" >&2; return 1; }
    mkdir -p "$src"
    if [[ ! -e $src/$file ]]; then
        local IFS=:
        for dir in ${JOE_SOURCE_CACHE:-}; do
            if [[ -e $dir/$file ]]; then
                cp --reflink=auto "$dir/$file" "$src/$file.part" && mv "$src/$file.part" "$src/$file"
                break
            fi
        done
        unset IFS
    fi
    if [[ ! -e $src/$file && $url == git+* ]]; then
        # A commit of a git repository, as the tar file `git archive` makes
        # of it: AOSP's own archives are made on demand with the time of the
        # request in every header, so no two downloads are alike.
        local repo=${url#git+} commit tmp
        commit=${repo##*#}
        repo=${repo%#*}
        echo "fetch: $repo at $commit" >&2
        tmp=$(mktemp -d "$src/.git-XXXXXX")
        git -C "$tmp" init -q
        git -C "$tmp" fetch -q --depth 1 "$repo" "$commit"
        git -C "$tmp" archive --format=tar --prefix=src/ "$commit" >"$src/$file.part"
        rm -rf "$tmp"
        mv "$src/$file.part" "$src/$file"
    elif [[ ! -e $src/$file ]]; then
        echo "fetch: downloading $url" >&2
        curl -fsSL --retry 3 -o "$src/$file.part" "$url"
        mv "$src/$file.part" "$src/$file"
    fi
    echo "$sum  $src/$file" | sha256sum -c --quiet - || {
        echo "fetch: $file does not match bootstrap/sources" >&2
        return 1
    }
}

# step NAME FUNCTION [ARGS...]: run FUNCTION once, in build/bootstrap/work/NAME,
# with its output in build/bootstrap/logs/NAME.log. A marker records success,
# so a script that failed can be run again and continues where it stopped.
step() {
    local name=$1 fn=$2
    shift 2
    local done_dir=$top/build/bootstrap/done logs=$top/build/bootstrap/logs
    [[ -e $done_dir/$name ]] && return 0
    mkdir -p "$done_dir" "$logs"
    echo "==> $name"
    local started=$SECONDS
    rm -rf "$top/build/bootstrap/work/$name"
    mkdir -p "$top/build/bootstrap/work/$name"
    # Not `if ! (...)`: in a condition bash ignores set -e, even inside the
    # subshell, and a step would go on after a failed command.
    local status
    set +e
    (cd "$top/build/bootstrap/work/$name" || exit 1; set -e; "$fn" "$@") >"$logs/$name.log" 2>&1
    status=$?
    set -e
    if ((status != 0)); then
        echo "FAILED: $name (see $logs/$name.log)" >&2
        tail -n 40 "$logs/$name.log" >&2
        exit 1
    fi
    rm -rf "$top/build/bootstrap/work/$name"
    touch "$done_dir/$name"
    echo "    $((SECONDS - started))s"
}

# unpack FILE: extract build/src/FILE into the current directory, dropping its
# top-level directory.
unpack() {
    fetch "$1"
    tar -xf "$src/$1" --strip-components=1
}
