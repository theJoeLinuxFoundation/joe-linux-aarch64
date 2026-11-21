# Only the device-mapper half of the LVM2 source is built: libdevmapper,
# dmsetup and the dm udev rules, which is what cryptsetup needs. The logical
# volume manager itself (lvm, its units and libaio, which only it uses) is
# left out.
build() {
    # lvm2's Makefiles have a variable of their own called SOURCES; the build
    # driver's environment variable of that name must not leak into make.
    unset SOURCES
    ./configure --prefix=/usr \
        --enable-pkgconfig \
        --enable-udev_sync \
        --enable-udev_rules \
        --with-udevdir=/usr/lib/udev/rules.d \
        --without-systemd \
        --without-libaio \
        --disable-readline \
        --disable-selinux \
        --disable-nls
    make device-mapper
}

package() {
    unset SOURCES
    make DESTDIR="$DESTDIR" install_device-mapper
}
