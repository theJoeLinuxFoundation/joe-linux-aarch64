prepare() {
    # The system-wide configuration file is /etc/vimrc.
    echo '#define SYS_VIMRC_FILE "/etc/vimrc"' >> src/feature.h
}

build() {
    # A console editor for the base system. The book's bare "./configure
    # --prefix=/usr" takes whatever it finds, and the shared build root holds
    # GTK, X11, Wayland, pixman, libcanberra and the rest of the desktop, so
    # everything that would be picked up from there is switched off by name:
    # no GUI, no X or Wayland clipboard, no sound, no gpm mouse, no libsodium
    # encryption, no Smack labels (which would link libattr). The script
    # interpreters (perl, python, lua, ruby, tcl) are off by default.
    ./configure --prefix=/usr \
        --with-features=huge \
        --enable-gui=no \
        --without-x \
        --without-wayland \
        --disable-pixman \
        --disable-canberra \
        --disable-libsodium \
        --disable-gpm \
        --disable-sysmouse \
        --disable-selinux \
        --disable-smack \
        --disable-desktop-database-update \
        --disable-icon-cache-update
    make
}

package() {
    make DESTDIR="$DESTDIR" install

    # vi is vim, as is its manual page in every language.
    ln -sv vim "$DESTDIR/usr/bin/vi"
    local page
    for page in "$DESTDIR"/usr/share/man/{,*/}man1/vim.1; do
        ln -sv vim.1 "$(dirname "$page")/vi.1"
    done

    # No GUI is built, so the menu entries (vim.desktop, gvim.desktop) and
    # their icons would only add a launcher that opens a terminal.
    rm -rf "$DESTDIR/usr/share/applications" "$DESTDIR/usr/share/icons"

    install -d "$DESTDIR/etc"
    cat > "$DESTDIR/etc/vimrc" << "EOF"
" Begin /etc/vimrc

" Ensure defaults are set before customizing settings, not after
source $VIMRUNTIME/defaults.vim
let skip_defaults_vim=1

set nocompatible
set backspace=2
set mouse=
syntax on
if (&term == "xterm") || (&term == "putty")
  set background=dark
endif

" End /etc/vimrc
EOF
}
