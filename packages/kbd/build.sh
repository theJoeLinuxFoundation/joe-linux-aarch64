# LFS chapter 8. loadkeys and setfont configure a virtual console directly.
# The systemd-vconsole-setup service that runs them on joe Linux is absent here.

prepare() {
    # The Backspace and Delete keys behave consistently in every keymap.
    patch -Np1 -i "$SOURCES/kbd-2.10.0-backspace-1.patch"
    # resizecons does not work with current kernels.
    sed -i '/RESIZECONS_PROGS=/s/yes/no/' configure
    sed -i 's/resizecons.8 //' docs/man/man8/Makefile.in
}

build() {
    # vlock needs Linux-PAM and is not wanted on the console. The XKB
    # conversion (keymaps made from X keyboard layouts) would link
    # libxkbcommon, which the base system does not have; it is off.
    ./configure --prefix=/usr --disable-vlock --disable-xkb
    make
}

package() {
    make DESTDIR="$DESTDIR" install
}
