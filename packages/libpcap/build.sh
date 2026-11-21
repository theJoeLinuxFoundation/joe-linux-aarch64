build() {
    # Use libnl for Wi-Fi monitor mode and usbmon for USB capture.
    # Bluetooth needs BlueZ headers, D-Bus capture needs libdbus and RDMA
    # needs rdma-core. None is packaged here. Keep remote capture off.
    ./configure --prefix=/usr \
        --enable-ipv6 \
        --with-libnl \
        --disable-bluetooth \
        --disable-dbus \
        --enable-usb \
        --disable-rdma \
        --disable-remote
    # The static library is not installed.
    sed -i '/INSTALL_DATA.*libpcap.a\|RANLIB.*libpcap.a/ s/^/#/' Makefile
    make
}

package() {
    make DESTDIR="$DESTDIR" install
}
