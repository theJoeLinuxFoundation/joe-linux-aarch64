build() {
    # Compress::Raw::Zlib and Compress::Raw::Bzip2 link against the system
    # libraries instead of the copies bundled with perl.
    export BUILD_ZLIB=False
    export BUILD_BZIP2=0
    sh Configure -des \
        -D prefix=/usr \
        -D vendorprefix=/usr \
        -D privlib=/usr/lib/perl5/5.44/core_perl \
        -D archlib=/usr/lib/perl5/5.44/core_perl \
        -D sitelib=/usr/lib/perl5/5.44/site_perl \
        -D sitearch=/usr/lib/perl5/5.44/site_perl \
        -D vendorlib=/usr/lib/perl5/5.44/vendor_perl \
        -D vendorarch=/usr/lib/perl5/5.44/vendor_perl \
        -D man1dir=/usr/share/man/man1 \
        -D man3dir=/usr/share/man/man3 \
        -D pager="/usr/bin/less -isR" \
        -D useshrplib \
        -D usethreads
    make
}

package() {
    export BUILD_ZLIB=False
    export BUILD_BZIP2=0
    make DESTDIR="$DESTDIR" install
}
