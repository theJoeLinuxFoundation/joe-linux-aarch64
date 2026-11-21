# Beyond LFS has no page for bash-completion. This is upstream's newest
# release, built the way its README says.

build() {
    ./configure --prefix=/usr --sysconfdir=/etc
    make
}

package() {
    # profiledir: upstream puts the script that loads completion into
    # interactive shells in /etc/profile.d. In joe Linux, settings shipped by
    # packages live in /usr/lib/joe/profile.d (see joe-filesystem): that
    # directory is read for every user, root included, while /etc/profile.d
    # is the administrator's and is not read by root shells.
    make DESTDIR="$DESTDIR" profiledir=/usr/lib/joe/profile.d install
    test -f "$DESTDIR/usr/lib/joe/profile.d/bash_completion.sh"
}
