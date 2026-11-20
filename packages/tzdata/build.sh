# The time zone data, compiled as Linux From Scratch compiles it on its glibc
# page, with the zic of the same release. bionic reads these files
# (/usr/share/zoneinfo, and /etc/localtime for the system's zone). posix/
# and right/ are directories, not links.

# The code and the data unpack into one directory, as the tz distribution
# means them to: tzcode's Makefile takes the data's files for the version it
# builds into zic. The files both carry are the same. VERSION: there is no
# git checkout to describe, and without it the Makefile would call the
# version "2026f-dirty".
unpack() {
    tar -xf "$SOURCES/$PKG_SOURCE" --no-same-owner --no-same-permissions
    tar -xf "$SOURCES/tzcode2026f.tar.gz" --no-same-owner --no-same-permissions
}

# NETBSD_INSPIRED=0, as tzcode's Makefile describes: zic does not use the
# NetBSD functions (tzalloc, localtime_rz and the rest), which bionic's
# <time.h> declares with its own timezone_t, as NetBSD's does.
build() {
    make CC=cc VERSION="$PKG_VERSION" CPPFLAGS=-DNETBSD_INSPIRED=0 zic
}

package() {
    local zoneinfo="$DESTDIR/usr/share/zoneinfo" tz zic=./zic
    mkdir -p "$zoneinfo"/{posix,right}
    for tz in etcetera southamerica northamerica europe africa antarctica asia australasia backward; do
        "$zic" -L /dev/null -d "$zoneinfo" "$tz"
        "$zic" -L /dev/null -d "$zoneinfo/posix" "$tz"
        "$zic" -L leapseconds -d "$zoneinfo/right" "$tz"
    done
    cp zone.tab zone1970.tab iso3166.tab "$zoneinfo"
    "$zic" -d "$zoneinfo" -p America/New_York
}
