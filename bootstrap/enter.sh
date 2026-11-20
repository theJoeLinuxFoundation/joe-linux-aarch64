#!/bin/bash
# Runs a command inside the build root, as root in a user namespace.
#
#   enter.sh [--net] COMMAND...
#
# The build root is mounted read-write at /, the downloaded sources read-only
# at /sources, and build/bootstrap/work at /build. There is no network unless
# --net is given.
#
# The build root's programs are aarch64: an aarch64 machine runs them
# natively, an x86_64 one with qemu-user, registered with binfmt_misc. The
# compiler is the exception: the toolchain in /usr/lib/joe-cross is a
# program for this machine and runs at native speed, which is why it comes
# first in PATH.
set -euo pipefail

top=$(cd "$(dirname "$0")/.." && pwd)
root=$top/build/bootstrap/root
net=--unshare-net
if [[ ${1:-} == --net ]]; then net=; shift; fi

mkdir -p "$top/build/bootstrap/work" "$root"/{dev,proc,sys,run,tmp,build,sources}
exec bwrap --unshare-user --uid 0 --gid 0 --cap-add ALL $net \
    --unshare-ipc --unshare-uts --hostname joe-build --die-with-parent \
    --bind "$root" / --dev /dev --proc /proc --tmpfs /run --tmpfs /tmp \
    --bind "$top/build/bootstrap/work" /build \
    --ro-bind "$top/build/src" /sources \
    --clearenv --setenv HOME /root --setenv TERM "${TERM:-dumb}" \
    --setenv PATH /usr/lib/joe-cross/bin:/usr/bin:/usr/sbin --setenv LC_ALL POSIX \
    --setenv MAKEFLAGS "-j$(nproc)" --setenv FORCE_UNSAFE_CONFIGURE 1 \
    --setenv CONFIG_SITE /usr/share/joe/config.site \
    --chdir / "$@"
