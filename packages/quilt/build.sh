# Not in the book: the newest upstream release, built as its README says.
build() {
    # diffstat enables refresh --diffstat. Leave out 7zip (.7z patches),
    # rpmbuild (quilt setup of .spec files) and sendmail (quilt mail falls
    # back to its own way of writing the messages).
    ./configure --prefix=/usr \
        --sysconfdir=/etc \
        --enable-nls \
        --with-diffstat=/usr/bin/diffstat \
        --without-7z \
        --without-rpmbuild \
        --without-sendmail
    make
}

package() {
    # quilt's Makefile calls the staging directory BUILD_ROOT.
    make BUILD_ROOT="$DESTDIR" install

    # bash-completion loads completions on demand from here;
    # /etc/bash_completion.d is its older directory, read eagerly at every
    # shell start.
    install -d "$DESTDIR/usr/share/bash-completion/completions"
    mv -v "$DESTDIR/etc/bash_completion.d/quilt" "$DESTDIR/usr/share/bash-completion/completions/quilt"
    rmdir "$DESTDIR/etc/bash_completion.d"
}
