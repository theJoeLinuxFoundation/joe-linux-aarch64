# Following the book's zsh page, without the HTML, PDF and Info manuals
# (the manual pages are installed). The book's /etc/zsh/zprofile is replaced
# by one that gives zsh login shells the environment bash login shells get
# from joe Linux's /usr/lib/joe/profile. The book's addition to /etc/shells
# is not made here: that file is joe-filesystem's.
prepare() {
    # Test membership before indexing the file-substitution table. Repeated
    # lookups of a missing entry in the native gawk can otherwise swallow
    # make recipes beginning with @ and ending in $@, including install.bin.
    sed -i 's/if (F\[key\] != ""/if ((key in F) \&\& F[key] != ""/' configure
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
    test -x "$DESTDIR/usr/bin/zsh"
    test -s "$DESTDIR/usr/share/man/man1/zsh.1"
    test -s "$DESTDIR/usr/lib/zsh/$PKG_VERSION/zsh/pcre.so"

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
