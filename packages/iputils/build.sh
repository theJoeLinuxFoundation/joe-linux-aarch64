# Not in the book: the newest upstream release, built as its README says.
build() {
    mkdir build
    cd build
    # No ping: Linux From Scratch takes ping from inetutils, and so does joe.
    # The manual pages ship ready-made in the tarball. Capabilities are
    # dropped with libcap; host names may be internationalised (libidn2).
    # NO_SETCAP_OR_SUID: meson's install script would call setcap; see
    # package().
    meson setup .. \
        --prefix=/usr \
        --libdir=lib \
        --buildtype=release \
        -D INSTALL_SYSTEMD_UNITS=false \
        -D BUILD_PING=false \
        -D BUILD_ARPING=true \
        -D BUILD_TRACEPATH=true \
        -D BUILD_CLOCKDIFF=true \
        -D USE_CAP=true \
        -D USE_IDN=true \
        -D USE_GETTEXT=true \
        -D BUILD_MANS=true \
        -D BUILD_HTML_MANS=false \
        -D NO_SETCAP_OR_SUID=true \
        -D SKIP_TESTS=true
    ninja
}

package() {
    cd build
    DESTDIR="$DESTDIR" ninja install
    # Upstream gives clockdiff CAP_NET_RAW and CAP_SYS_NICE with setcap, or
    # makes it set-uid root where setcap is unavailable, as here. It keeps
    # only those two capabilities. arping, as upstream ships it, needs root.
    chmod 4755 "$DESTDIR/usr/bin/clockdiff"
}
