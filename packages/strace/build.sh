# Not in the book: the newest upstream release, built as its README says.
prepare() {
    # This probe deliberately gives the kernel a null mask to distinguish
    # EINVAL from EFAULT. Bionic's libc wrapper requires a non-null mask.
    sed -i '/#include <sched.h>/a #include <sys/syscall.h>
            s/sched_getaffinity(0, cpuset_size, NULL)/syscall(SYS_sched_getaffinity, 0, cpuset_size, NULL)/' src/affinity.c
}

build() {
    # No stack traces (-k): elfutils' libdw and the standalone libunwind
    # are not packaged on ARM. There is no 32-bit toolchain, so no decoding
    # of 32-bit processes (mpers). No SELinux. The terminal width comes from
    # ncurses' terminfo, which configure picks up without a switch.
    ./configure --prefix=/usr \
        --enable-stacktrace=no \
        --without-libdw \
        --without-libunwind \
        --without-libiberty \
        --without-libselinux \
        --enable-mpers=no
    make
}

package() {
    make DESTDIR="$DESTDIR" install
}
