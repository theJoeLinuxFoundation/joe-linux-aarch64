# The time zone data, compiled as Linux From Scratch compiles it on its glibc
# page, with the zic of the same release. bionic reads these files
# (/usr/share/zoneinfo, and /etc/localtime for the system's zone). posix/
# and right/ are directories, not links.

unpack() {
    tar -xf "$SOURCES/$PKG_SOURCE" --no-same-owner --no-same-permissions
    mkdir tzcode
    tar -xf "$SOURCES/tzcode2026f.tar.gz" -C tzcode --no-same-owner --no-same-permissions
}

build() {
    make -C tzcode CC=cc zic
}

package() {
    local zoneinfo="$DESTDIR/usr/share/zoneinfo" tz zic=./tzcode/zic
    mkdir -p "$zoneinfo"/{posix,right}
    for tz in etcetera southamerica northamerica europe africa antarctica asia australasia backward; do
        "$zic" -L /dev/null -d "$zoneinfo" "$tz"
        "$zic" -L /dev/null -d "$zoneinfo/posix" "$tz"
        "$zic" -L leapseconds -d "$zoneinfo/right" "$tz"
    done
    cp zone.tab zone1970.tab iso3166.tab "$zoneinfo"
    "$zic" -d "$zoneinfo" -p America/New_York
}
