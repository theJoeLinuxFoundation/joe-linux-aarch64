# Not in the book: the newest release on CPAN, built as its README describes.
# The SHA-256 is the one metacpan publishes for the release. It also
# installs the crc32 program (script/crc32).
build() {
    # Installed as a vendor module. perllocal.pod and .packlist are shared
    # bookkeeping files that every module would otherwise write to.
    perl Makefile.PL INSTALLDIRS=vendor NO_PERLLOCAL=1 NO_PACKLIST=1
    make
}

package() {
    make DESTDIR="$DESTDIR" install
}
