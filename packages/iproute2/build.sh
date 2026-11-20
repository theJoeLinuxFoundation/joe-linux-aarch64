prepare() {
    # arpd needs Berkeley DB, which is not shipped.
    sed -i /ARPD/d Makefile
    rm -f man/man8/arpd.8

    # iproute2 carries the kernel's headers, unprocessed, and searches them
    # first. bionic's <netinet/in.h> is built on bionic's processed copies of
    # these three (its in_addr_t comes with <linux/in.h>), and the kernel's
    # libc-compat.h only stands back for glibc: the C library's are used.
    rm include/uapi/linux/in.h include/uapi/linux/in6.h include/uapi/linux/libc-compat.h
}

build() {
    # The Makefile sets CC := gcc, which only the command line overrides, and
    # hands it to its configure; joe's is LLVM's (the driver's CC). HOSTCC,
    # for the tools it runs while building, follows CC.
    make CC="$CC" NETNS_RUN_DIR=/run/netns
}

package() {
    make CC="$CC" DESTDIR="$DESTDIR" NETNS_RUN_DIR=/run/netns SBINDIR=/usr/sbin install
}
