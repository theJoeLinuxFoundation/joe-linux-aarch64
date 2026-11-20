#!/bin/bash
# Runs inside the build root, as root in a user namespace with no network.
# Sources /recipe/build.sh and calls, in order:
#
#   unpack    (default: extract $SOURCES/$PKG_SOURCE into the current directory)
#   prepare   (default: nothing)    patches and source fixes
#   build     (default: nothing)    configure and compile
#   package   (required)           install into $DESTDIR
#
# All four run in /build/src. Afterwards the staged tree is tidied the same
# way for every package.
set -euo pipefail
umask 022

# joe Linux ARM: the build root is an aarch64 system whose programs run
# natively on an aarch64 build machine and under qemu-user on an x86_64 one,
# but its compiler is the toolchain in /usr/lib/joe-cross, a program for the
# build machine, which always runs at its speed. It comes first,
# so that cc, c++, ld, ar, nm, strip and the rest are LLVM's. There is no
# GCC or binutils in joe Linux ARM.
if [[ -d /usr/lib/joe-cross/bin ]]; then
    export PATH=/usr/lib/joe-cross/bin:$PATH
fi
export CC=${CC:-cc} CXX=${CXX:-c++} AR=${AR:-llvm-ar} RANLIB=${RANLIB:-llvm-ranlib}
export NM=${NM:-llvm-nm} STRIP=${STRIP:-llvm-strip} OBJCOPY=${OBJCOPY:-llvm-objcopy}
export OBJDUMP=${OBJDUMP:-llvm-objdump} READELF=${READELF:-llvm-readelf}

# gettext is libintl's on bionic (glibc has it in libc), and builds written
# for glibc often leave $(LIBINTL) out of a link: a library then calls
# libintl_gettext without needing libintl, and every program linked with it
# fails. Once gettext is installed, every link is given libintl, which lld
# records only where something uses it (--as-needed).
if [[ -e /usr/lib/libintl.so ]]; then
    export LDFLAGS="${LDFLAGS:+$LDFLAGS }-Wl,--push-state,--as-needed,-lintl,--pop-state"
fi

# Configure scripts are told the system is aarch64-unknown-linux-android,
# what config.guess says of bionic (clang defines __ANDROID__), whatever
# version of config.guess a package carries. gnulib, in most of the GNU
# userland, knows bionic by that name and compiles its workarounds for it,
# which its C code, seeing __ANDROID__, then calls. Two things are taken
# back where an Android host would make them wrong for a Linux system:
# libtool's packaging (libtool_as_linux, below) and Python, whose recipe
# says linux-gnu. A recipe sets ac_cv_build and ac_cv_host to say otherwise
# (--host does not override a cached host). The target is named too:
# configure scripts that ask for it (ncurses's) otherwise derive it from an
# empty host alias, the host being cached.
cat > /build/config.site <<'EOT'
ac_cv_build=${ac_cv_build-aarch64-unknown-linux-android}
ac_cv_host=${ac_cv_host-aarch64-unknown-linux-android}
ac_cv_target=${ac_cv_target-aarch64-unknown-linux-android}
EOT
export CONFIG_SITE=/build/config.site
# GNU tar run as root restores the owners recorded in an archive, which the
# user namespace cannot map; recipes that unpack extra tarballs would fail.
# Packaged files are root's anyway.
export TAR_OPTIONS=--no-same-owner

unpack() {
    tar -xf "$SOURCES/$PKG_SOURCE" --strip-components=1 --no-same-owner --no-same-permissions
}
prepare() { :; }
build() { :; }

# libtool's case for an Android host is how Android apps package libraries:
# no versioned sonames (an APK holds no symbolic links) and a run path in
# every library. joe Linux ARM packages them as a Linux system does, so in
# the configure scripts about to run, libtool's Android case is renamed out
# of the way and the host matches the next one, GNU/Linux's ("linux*").
# It runs after prepare(), which may regenerate them.
libtool_as_linux() {
    local f
    while IFS= read -r -d '' f; do
        if grep -q '^linux\*android\*)$' "$f"; then
            sed -i 's/^linux\*android\*)$/linux*android-libtool-as-linux*)/' "$f"
        fi
    done < <(find . -name configure -type f -print0)
}

# shellcheck disable=SC1091
source /recipe/build.sh
declare -F package >/dev/null || { echo "build.sh does not define package()" >&2; exit 1; }

# Each step starts in the source directory, whatever the previous one did.
set -x
cd /build/src
[[ -z ${PKG_SOURCE:-} ]] || unpack
cd /build/src
prepare
cd /build/src
libtool_as_linux
cd /build/src
build
cd /build/src
package
set +x

cd "$DESTDIR"

# /var is a subvolume shared by every deployment and /run and /tmp are
# temporary file systems, so nothing a package puts there would ever be seen.
# What a program needs there is created at boot by tmpfiles.d.
if [[ $PKG_NAME != joe-filesystem ]]; then
    rm -rf var run tmp
fi

# Libtool archives only cause trouble; documentation readers are not shipped yet.
# Only gtk-doc's html directory is API documentation: gtk-doc itself keeps its
# Python modules and stylesheets beside it in /usr/share/gtk-doc.
find . -name '*.la' -delete
rm -rf usr/share/doc usr/share/info usr/share/gtk-doc/html

# Python byte code. A .pyc file normally records its source file's mtime and
# is used only while the source still has it; dave does not keep file times,
# so on an installed system every .pyc would be stale. Python would then
# compile every module again on each import, and when run by root it would
# write unsealed .pyc files that a privileged Python is not allowed to load.
# So each .pyc records a hash of its source instead (PEP 552,
# "checked-hash"): the code inside is unchanged, only the header is. When
# python itself is being packaged, the interpreter just built does it, so
# the hashes match its version.
if [[ -n $(find . -path '*/__pycache__/*.pyc' -print -quit) ]]; then
    python=(python3)
    if [[ -x usr/bin/python3 ]]; then
        python=(env "LD_LIBRARY_PATH=$DESTDIR/usr/lib" "$DESTDIR/usr/bin/python3")
    fi
    "${python[@]}" -I -S - <<'EOF'
import importlib.util, os, sys
tag = "." + sys.implementation.cache_tag
done = other = 0
for top, dirs, files in os.walk("."):
    if os.path.basename(top) != "__pycache__":
        continue
    for name in files:
        if not name.endswith(".pyc") or tag not in name:
            continue
        path = os.path.join(top, name)
        source = os.path.join(os.path.dirname(top), name[:name.index(tag)] + ".py")
        with open(path, "rb") as f:
            header = f.read(16)
        if header[:4] != importlib.util.MAGIC_NUMBER:
            other += 1
            continue
        if int.from_bytes(header[4:8], "little") != 0 or not os.path.exists(source):
            continue  # already hash-based, or no source to check against
        with open(source, "rb") as f:
            digest = importlib.util.source_hash(f.read())
        with open(path, "r+b") as f:
            f.seek(4)
            f.write((0b11).to_bytes(4, "little") + digest)
        done += 1
print(f"python byte code: {done} files made hash-based", file=sys.stderr)
if other:
    print(f"python byte code: {other} files are for another Python version", file=sys.stderr)
EOF
fi

# Strip debugging symbols unless the recipe opts out with NOSTRIP=1.
if [[ -z ${NOSTRIP:-} ]]; then
    while IFS= read -r -d '' f; do
        case $(head -c 4 "$f" | od -An -c | tr -d ' ') in
            '177ELF') ;;
            *) case $f in
                   *.a) "$STRIP" --strip-debug "$f" 2>/dev/null || true ;;
               esac
               continue ;;
        esac
        case $f in
            *.ko | *.ko.*) ;;
            *.o) "$STRIP" --strip-debug "$f" 2>/dev/null || true ;;
            *) "$STRIP" --strip-unneeded "$f" 2>/dev/null || true ;;
        esac
    done < <(find . -type f -print0)
fi

# Empty directories that only existed to hold what was removed above.
find . -depth -type d -empty -path './usr/share/*' -delete 2>/dev/null || true
