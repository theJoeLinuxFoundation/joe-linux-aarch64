#!/bin/bash
# Stage 2 of the joe Linux ARM bootstrap: the temporary tools that let the
# build root build packages, following chapters 6 and 7 of Linux From
# Scratch (systemd, r13.1) with the same versions.
#
#   A. cross-compiled from this machine into build/bootstrap/root: m4,
#      ncurses, bash, coreutils, diffutils, file, findutils, gawk, grep,
#      gzip, make, patch, sed, tar, xz, bzip2, zstd, ninja;
#   B. built inside the build root (bootstrap/enter.sh): gettext, bison,
#      perl, Python, texinfo, util-linux, cmake.
#
# ninja and cmake are not in Linux From Scratch's chapters: bionic's own
# build uses them (packages/bionic), and bionic is the first package built.
#
# The cross-compiled tools are configured with --host and no --build, and
# the test programs configure compiles run, through bionic's dynamic linker
# in the build root, so configure finds that it is not cross-compiling and
# tests what it would test on the machine itself. There are therefore no
# cross-compilation guesses to supply, and a package's own build tools run
# as they would on the target. On an x86_64 machine qemu-user runs them, with
# QEMU_LD_PREFIX naming the build root. On an aarch64 machine they run
# natively, but this machine's /usr/lib is not joe's: they are linked to
# find the dynamic linker and libraries in the build root instead, and once
# a step is installed, bootstrap/joe-paths.py gives its files joe's paths.
#
# Nothing made here ships: every package in packages/ replaces these.
set -euo pipefail
top=$(cd "$(dirname "$0")/.." && pwd)
source "$top/bootstrap/lib.sh"

root=$top/build/bootstrap/root
cross=$root/usr/lib/joe-cross
[[ -e $top/build/bootstrap/done/stage1-check ]] || { echo "run stage1.sh first" >&2; exit 1; }

host=aarch64-unknown-linux-android
jobs=$(nproc)
if [[ $JOE_HOST_ARCH == "$JOE_ARCH" ]]; then
    native_flags=("-Wl,--dynamic-linker=$root$JOE_INTERP" "-Wl,-rpath,$root/usr/lib")
    export LDFLAGS="${native_flags[*]}"
else
    export QEMU_LD_PREFIX=$root
fi
export PATH=$cross/bin:$hosttools/bin:/usr/bin
export CC=clang CXX=clang++ AR=llvm-ar RANLIB=llvm-ranlib NM=llvm-nm STRIP=llvm-strip
export OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump READELF=llvm-readelf
export MAKEFLAGS=-j$jobs

# gnu TARBALL [CONFIGURE ARGS...]: the usual configure, make, make install.
gnu() {
    unpack "$1"
    shift
    ./configure --prefix=/usr --host=$host "$@"
    make
    make DESTDIR="$root" install
}

# --- A. Cross-compiled ------------------------------------------------------

m4() { gnu m4-1.4.21.tar.xz; }

ncurses() {
    gnu ncurses-6.6.tar.gz --mandir=/usr/share/man --with-manpage-format=normal \
        --with-shared --without-normal --with-cxx-shared --without-debug --without-ada \
        --disable-stripping
    ln -sf libncursesw.so "$root/usr/lib/libncurses.so"
    sed -e 's/^#if.*XOPEN.*$/#if 1/' -i "$root/usr/include/curses.h"
}

bash_() {
    gnu bash-5.3.tar.gz --without-bash-malloc
    ln -sf bash "$root/usr/bin/sh"
}

coreutils() {
    gnu coreutils-9.12.tar.xz --enable-install-program=hostname --enable-no-install-program=kill,uptime
    mv "$root/usr/bin/chroot" "$root/usr/sbin/"
}

diffutils() { gnu diffutils-3.12.tar.xz; }
file_() { gnu file-5.48.tar.gz; }
findutils() { gnu findutils-4.11.0.tar.xz --localstatedir=/var/lib/locate; }

gawk() {
    unpack gawk-5.4.1.tar.xz
    sed -i 's/extras//' Makefile.in
    ./configure --prefix=/usr --host=$host
    make
    make DESTDIR="$root" install
}

grep_() { gnu grep-3.12.tar.xz; }
gzip_() { gnu gzip-1.15.tar.xz; }
make_() { gnu make-4.4.1.tar.gz --without-guile; }
patch_() { gnu patch-2.8.1.tar.xz; }
sed_() { gnu sed-4.10.tar.xz; }
tar_() { gnu tar-1.35.tar.xz; }
xz() { gnu xz-5.8.4.tar.xz --disable-static --docdir=/usr/share/doc/xz-5.8.4; }

# A plain makefile; the tools only, statically linked against libbz2.
bzip2() {
    unpack bzip2-1.0.8.tar.gz
    make CC="$CC" AR="$AR" RANLIB="$RANLIB" bzip2 bzip2recover
    install -m755 bzip2 bzip2recover "$root/usr/bin/"
    ln -sf bzip2 "$root/usr/bin/bunzip2"
    ln -sf bzip2 "$root/usr/bin/bzcat"
}

zstd() {
    unpack zstd-1.5.7.tar.gz
    make CC="$CC" AR="$AR" zstd-release -C programs
    install -m755 programs/zstd "$root/usr/bin/zstd"
    ln -sf zstd "$root/usr/bin/unzstd"
    ln -sf zstd "$root/usr/bin/zstdcat"
}

# configure.py writes a build.ninja for the compiler in CXX, which this
# machine's ninja runs.
ninja_() {
    unpack ninja-1.13.2.tar.gz
    python3 configure.py
    "$hosttools/bin/ninja"
    install -m755 ninja "$root/usr/bin/ninja"
}

# cross_step NAME FUNCTION: a step that runs FUNCTION and then, on an
# aarch64 machine, gives the build root's files joe's paths back.
cross_build() {
    "$1"
    if [[ $JOE_HOST_ARCH == "$JOE_ARCH" ]]; then
        python3 -I "$top/bootstrap/joe-paths.py" "$root" "$JOE_INTERP" "${native_flags[@]}"
    fi
}
cross_step() { step "$1" cross_build "$2"; }

cross_step m4 m4
cross_step ncurses ncurses
cross_step bash bash_
cross_step coreutils coreutils
cross_step diffutils diffutils
cross_step file file_
cross_step findutils findutils
cross_step gawk gawk
cross_step grep grep_
cross_step gzip gzip_
cross_step make make_
cross_step patch patch_
cross_step sed sed_
cross_step tar tar_
cross_step xz xz
cross_step bzip2 bzip2
cross_step zstd zstd
cross_step ninja ninja_

# --- B. Inside the build root -------------------------------------------------

enter=$top/bootstrap/enter.sh

# What packages/.build/driver.sh gives every package build: configure
# scripts are told the system is Linux, not Android (see the driver).
mkdir -p "$root/usr/share/joe"
cat > "$root/usr/share/joe/config.site" <<'EOT'
ac_cv_build=${ac_cv_build-aarch64-unknown-linux-gnu}
ac_cv_host=${ac_cv_host-aarch64-unknown-linux-gnu}
ac_cv_target=${ac_cv_target-aarch64-unknown-linux-gnu}
EOT

# chroot NAME TARBALL COMMANDS: run COMMANDS in the build root, in the
# unpacked TARBALL (none if empty).
chroot_step() {
    local name=$1 tarball=$2 commands=$3
    local done_dir=$top/build/bootstrap/done logs=$top/build/bootstrap/logs
    [[ -e $done_dir/$name ]] && return 0
    [[ -n $tarball ]] && fetch "$tarball"
    echo "==> $name"
    local started=$SECONDS dir=/build/$name
    if ! env -u QEMU_LD_PREFIX "$enter" /usr/bin/bash -euc "
        rm -rf $dir && mkdir -p $dir && cd $dir
        ${tarball:+tar -xf /sources/$tarball --strip-components=1 --no-same-owner}
        $commands
        cd / && rm -rf $dir
    " >"$logs/$name.log" 2>&1; then
        echo "FAILED: $name (see $logs/$name.log)" >&2
        tail -n 40 "$logs/$name.log" >&2
        exit 1
    fi
    touch "$done_dir/$name"
    echo "    $((SECONDS - started))s"
}

# Directories and files every build expects. In the finished system these
# come from the joe-filesystem package; here they only make the build root
# usable.
chroot_step layout "" '
    mkdir -p /{boot,home,mnt,opt,srv} /etc/opt /usr/{,local/}{include,src}
    mkdir -p /usr/local/{bin,lib,sbin} /usr/{,local/}share/{doc,info,locale,man,misc,terminfo,zoneinfo}
    mkdir -p /usr/{,local/}share/man/man{1..8} /var/{cache,local,log,mail,opt,spool,lib,tmp} /root
    ln -sfn /run /var/run
    ln -sfn /run/lock /var/lock
    chmod 0750 /root
    chmod 1777 /var/tmp
    ln -sfn /proc/self/mounts /etc/mtab
    printf "127.0.0.1  localhost\n::1        localhost\n" > /etc/hosts
    cat > /etc/passwd <<"EOT"
root:x:0:0:root:/root:/bin/bash
bin:x:1:1:bin:/dev/null:/usr/bin/false
daemon:x:6:6:Daemon User:/dev/null:/usr/bin/false
nobody:x:65534:65534:Unprivileged User:/dev/null:/usr/bin/false
EOT
    cat > /etc/group <<"EOT"
root:x:0:
bin:x:1:daemon
sys:x:2:
kmem:x:3:
tape:x:4:
tty:x:5:
daemon:x:6:
floppy:x:7:
disk:x:8:
lp:x:9:
dialout:x:10:
audio:x:11:
video:x:12:
utmp:x:13:
clock:x:14:
cdrom:x:15:
adm:x:16:
input:x:24:
mail:x:34:
kvm:x:61:
wheel:x:97:
users:x:999:
nogroup:x:65534:
EOT
'

chroot_step gettext gettext-1.0.tar.xz '
    ./configure --disable-shared
    make
    cp gettext-tools/src/{msgfmt,msgmerge,xgettext} /usr/bin
'

chroot_step bison bison-3.8.2.tar.xz '
    ./configure --prefix=/usr --docdir=/usr/share/doc/bison-3.8.2
    make
    make install
'

chroot_step perl perl-5.44.0.tar.xz '
    sh Configure -des -D cc=clang -D prefix=/usr -D vendorprefix=/usr -D useshrplib \
        -D privlib=/usr/lib/perl5/5.44/core_perl -D archlib=/usr/lib/perl5/5.44/core_perl \
        -D sitelib=/usr/lib/perl5/5.44/site_perl -D sitearch=/usr/lib/perl5/5.44/site_perl \
        -D vendorlib=/usr/lib/perl5/5.44/vendor_perl -D vendorarch=/usr/lib/perl5/5.44/vendor_perl
    make
    make install
'

# For Python's zlib module: bionic's build reads the Unicode Character
# Database from its zip file.
chroot_step zlib zlib-1.4.tar.gz '
    ./configure --prefix=/usr
    make
    make install
'

# liblog: Python logs to Android's system log through it when it is embedded
# in an Android app, and configure adds it only for an Android system.
chroot_step python Python-3.15.2.tar.xz '
    ./configure --prefix=/usr --enable-shared --without-ensurepip --without-static-libpython \
        LIBS=-llog
    make
    make install
'

chroot_step texinfo texinfo-7.3.tar.xz '
    ./configure --prefix=/usr
    make
    make install
'

chroot_step util-linux util-linux-2.42.4.tar.xz '
    mkdir -p /var/lib/hwclock
    ./configure --libdir=/usr/lib --runstatedir=/run --disable-chfn-chsh --disable-login \
        --disable-nologin --disable-su --disable-setpriv --disable-runuser \
        --disable-pylibmount --disable-static --disable-liblastlog2 --without-python \
        --disable-makeinstall-chown --disable-makeinstall-setuid \
        ADJTIME_PATH=/var/lib/hwclock/adjtime
    make
    make install
'

# Its own copies of the libraries it uses, so that it needs nothing more
# from the build root than a C++ compiler.
chroot_step cmake cmake-4.4.5.tar.gz '
    # Compiled with __ANDROID__, cmake names its system Android (for Termux)
    # instead of asking uname; see packages/cmake/build.sh.
    sed -i -e "/^#elif defined(__ANDROID__)\$/{N;/return \"Android\";/d;}" \
        -e "s/^#if !defined(_WIN32) && !defined(__ANDROID__)\$/#if !defined(_WIN32)/" \
        Source/cmSystemTools.cxx
    if grep -q "return \"Android\";" Source/cmSystemTools.cxx; then exit 1; fi
    printf "/* 64-bit: nothing to rename. */\n" >Utilities/cmlibarchive/libarchive/android_lf.h
    ./bootstrap --prefix=/usr --parallel=$(nproc) --no-qt-gui -- \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_USE_OPENSSL=OFF -DBUILD_TESTING=OFF
    make
    make install
'

chroot_step cleanup "" '
    rm -rf /usr/share/{info,man,doc}/*
    find /usr/{lib,libexec} -name "*.la" -delete 2>/dev/null || true
'

echo "stage 2 complete: the build root is ready for dave build"
