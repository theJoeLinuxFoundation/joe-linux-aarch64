# Following the book's zsh page, without the HTML, PDF and Info manuals
# (the manual pages are installed). The book's /etc/zsh/zprofile is replaced
# by one that gives zsh login shells the environment bash login shells get
# from joe Linux's /usr/lib/joe/profile. The book's addition to /etc/shells
# is not made here: that file is joe-filesystem's.
prepare() {
    # Keep config.status from reading the silent recursive make command as
    # an @file@ substitution. Without it, the module objects are never built.
    sed -i 's/^\(\s*\)@$(MAKE) -f Makemod/\1$(MAKE) -f Makemod/' Src/Makefile.in
    sed -e 's|/etc/z|/etc/zsh/z|g' -i Doc/*.*
}

build() {
    ./configure --prefix=/usr \
        --sysconfdir=/etc/zsh \
        --enable-etcdir=/etc/zsh \
        --enable-cap \
        --enable-gdbm \
        --enable-pcre
    make
}

package() {
    make DESTDIR="$DESTDIR" install

    install -vdm755 "$DESTDIR/etc/zsh"
    cat > "$DESTDIR/etc/zsh/zprofile" << "EOF"
# Begin /etc/zsh/zprofile

# System-wide environment for login shells: the same as bash's, from
# /usr/lib/joe/profile (PATH, umask, and what packages put in
# /usr/lib/joe/profile.d; for users other than root also /etc/profile and
# /etc/profile.d). zsh keeps its own prompt.
_joe_ps1=$PS1
emulate sh -c '. /usr/lib/joe/profile'
PS1=$_joe_ps1
unset _joe_ps1

# End /etc/zsh/zprofile
EOF
}
