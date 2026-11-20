prepare() {
    # Makefile.SH preloads the libperl.so being built when one is installed
    # already (glibc's loader would prefer the installed one, which its RPATH
    # names, to LD_LIBRARY_PATH). bionic's loader, and lld's RUNPATH, let
    # LD_LIBRARY_PATH win anyway, and the preload reaches every program the
    # build starts: the compiler too, which on an aarch64 build machine is a
    # glibc program that cannot load a bionic libperl.so.
    grep -q 'if test -f \$archlib/CORE/\$libperl; then' Makefile.SH
    sed -i 's|if test -f \$archlib/CORE/\$libperl; then|if false; then|' Makefile.SH
}

build() {
    # Compress::Raw::Zlib and Compress::Raw::Bzip2 link against the system
    # libraries instead of the copies bundled with perl.
    export BUILD_ZLIB=False
    export BUILD_BZIP2=0
    # usenm=false: Configure finds the C library's functions by compiling and
    # linking tests, not by reading libc.so's symbols with nm. bionic's are
    # versioned (fprintf@@LIBC) and the library is stripped of the plain
    # symbol table, so nm gives Configure no names it recognises.
    sh Configure -des \
        -D usenm=false \
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
