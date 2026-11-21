prepare() {
    # Bionic threads cannot be cancelled. Keep the signal mask around fork,
    # but skip saving and restoring a cancellation state that does not exist.
    sed -i '/CHECK_BUG(pthread_setcancelstate/i #ifndef __ANDROID__
            /"disabling cancellation");/a #endif
            /"re-enabling cancellation");/a #endif' run-command.c
}

build() {
    # No Tcl/Tk in joe, so neither gitk nor git-gui. The book's optional
    # Rust parts can build offline, but this package uses the C implementation.
    ./configure --prefix=/usr \
        --with-gitconfig=/etc/gitconfig \
        --with-python=python3 \
        --with-libpcre2 \
        --with-curl \
        --with-expat \
        --with-openssl \
        --without-tcltk
    # This file applies to both make and make install. Git's Linux defaults
    # assume gettext is in libc, and the driver's -lintl masks that in the
    # configure probe. Tell Git to put -lintl with its link libraries.
    cat > config.mak <<'EOT'
NO_RUST = YesPlease
LIBC_CONTAINS_LIBINTL =
EOT
    make
}

package() {
    local sitelib
    sitelib=$(perl -MConfig -e 'print $Config{installsitelib}')
    make perllibdir="$sitelib" DESTDIR="$DESTDIR" install

    # The manual pages come prebuilt (building them needs asciidoc and xmlto).
    install -d "$DESTDIR/usr/share/man"
    tar -xf "$SOURCES/git-manpages-$PKG_VERSION.tar.xz" \
        -C "$DESTDIR/usr/share/man" --no-same-owner --no-overwrite-dir

    # The Subversion and CVS bridges need programs joe does not have
    # (Subversion's Perl bindings, cvs, cvsps).
    rm "$DESTDIR/usr/bin/git-cvsserver"
    rm "$DESTDIR"/usr/libexec/git-core/git-{svn,cvsimport,cvsexportcommit,cvsserver}
    rm -r "$DESTDIR$sitelib/Git/SVN" "$DESTDIR$sitelib/Git/SVN.pm"
    rm "$DESTDIR"/usr/share/man/man1/git-{svn,cvsimport,cvsexportcommit,cvsserver}.1
    rm "$DESTDIR/usr/share/man/man7/gitcvs-migration.7"

    # The prebuilt pages cover the Tk programs that were not built.
    rm "$DESTDIR"/usr/share/man/man1/{gitk,git-gui,git-citool}.1

    # Tab completion, loaded on demand by bash-completion when it is there.
    install -Dm644 contrib/completion/git-completion.bash \
        "$DESTDIR/usr/share/bash-completion/completions/git"
}
