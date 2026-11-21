# Following the book's sshfs page, without the optional manual page, which
# requires docutils' rst2man. Installing also links mount.sshfs and
# mount.fuse.sshfs in /usr/sbin, for mount -t fuse.sshfs and fstab.
build() {
    mkdir build
    cd build
    meson setup --prefix=/usr --buildtype=release ..
    ninja
}

package() {
    cd build
    DESTDIR="$DESTDIR" ninja install
}
