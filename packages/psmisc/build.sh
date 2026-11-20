build() {
    # Neither SELinux nor AppArmor exists here; both are off by default and
    # are named so that it stays that way.
    ./configure --prefix=/usr \
        --disable-selinux \
        --disable-apparmor
    make
}

package() {
    make DESTDIR="$DESTDIR" install
}
