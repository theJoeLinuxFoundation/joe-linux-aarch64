prepare() {
    # A privileged bash runs only sealed script files; see the patch's header.
    patch -Np1 -i /recipe/joe-sealed-scripts.patch
    # The system profile is a sealed file under /usr, so that a root shell
    # has one to read. It reads the administrator's /etc/profile for other users.
    sed -i 's|^#define SYS_PROFILE.*|#define SYS_PROFILE "/usr/lib/joe/profile"|' pathnames.h.in
    grep -q '"/usr/lib/joe/profile"' pathnames.h.in
    # Likewise a system-wide file for interactive shells that are not login
    # shells, such as those in a terminal window.
    sed -i 's|^/\* #define SYS_BASHRC .*|#define SYS_BASHRC "/usr/lib/joe/bashrc"|' config-top.h
    grep -q '^#define SYS_BASHRC "/usr/lib/joe/bashrc"' config-top.h
}

build() {
    ./configure --prefix=/usr \
        --without-bash-malloc \
        --with-installed-readline \
        --docdir=/usr/share/doc/bash-5.3
    make
}

package() {
    make DESTDIR="$DESTDIR" install
    # bash is the system's /bin/sh.
    ln -sf bash "$DESTDIR/usr/bin/sh"
}
