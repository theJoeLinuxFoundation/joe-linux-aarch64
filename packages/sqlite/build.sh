prepare() {
    # Only 32-bit Android needs SQLite's workaround that skips ftruncate
    # above 2 GiB. On aarch64 off_t is 64 bits.
    sed -i '/^static int robust_ftruncate(/,/^}/s/^#ifdef __ANDROID__$/#if defined(__ANDROID__) \&\& !defined(__LP64__)/' sqlite3.c
}

# Following the book's sqlite page, plus --soname=legacy. Without it
# SQLite's build gives libsqlite3.so no SONAME (upstream leaves that to
# packagers), so every program linked against it recorded the path
# /usr/lib/libsqlite3.so instead of a library name. "legacy" is the
# historical name, libsqlite3.so.0, which other distributions use too.
build() {
    ./configure --prefix=/usr \
        --disable-static \
        --soname=legacy \
        --enable-fts{4,5} \
        CPPFLAGS="-D SQLITE_ENABLE_COLUMN_METADATA=1 \
                  -D SQLITE_ENABLE_UNLOCK_NOTIFY=1 \
                  -D SQLITE_ENABLE_DBSTAT_VTAB=1 \
                  -D SQLITE_ENABLE_RTREE=1 \
                  -D SQLITE_SECURE_DELETE=1"
    make LDFLAGS.rpath=""
}

package() {
    make LDFLAGS.rpath="" DESTDIR="$DESTDIR" install
}
