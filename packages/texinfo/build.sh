# Following the book's Texinfo page (Linux From Scratch, chapter 8). It
# replaces the temporary copy built in stage 2. The book's rebuilding of
# /usr/share/info/dir is left out: the Info manuals are not shipped.
build() {
    ./configure --prefix=/usr
    make
}

package() {
    make DESTDIR="$DESTDIR" install
    # texinfo.tex and the other TeX support files, for when TeX is installed.
    make DESTDIR="$DESTDIR" TEXMF=/usr/share/texmf install-tex
}
