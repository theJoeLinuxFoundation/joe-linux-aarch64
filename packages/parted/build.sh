# Following the book's parted page.
prepare() {
    # The resize library uses libparted for FAT types and geometry. Build
    # libparted once its private libfs is ready, and record it in DT_NEEDED.
    sed -i '/^libparted_fs_resize_la_\(LIBADD\|DEPENDENCIES\) =/s/$/ ..\/libparted.la/' libparted/fs/Makefile.in
    cat >> libparted/fs/Makefile.in <<'EOF'

../libparted.la: libfs.la
	$(MAKE) -C .. libparted.la
EOF
}

build() {
    ./configure --prefix=/usr \
        --disable-static \
        --enable-device-mapper \
        --with-readline
    make
}

package() {
    make DESTDIR="$DESTDIR" install
}
