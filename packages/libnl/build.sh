prepare() {
    # netinet/in.h and net/if.h use bionic's processed kernel types.
    # Keep the other, newer netlink definitions from libnl.
    local header
    for header in libc-compat in in6 if; do
        printf '#include_next <linux/%s.h>\n' "$header" > "include/linux-private/linux/$header.h"
    done
}

build() {
    ./configure --prefix=/usr \
        --sysconfdir=/etc \
        --disable-static
    make
}

package() {
    make DESTDIR="$DESTDIR" install
}
