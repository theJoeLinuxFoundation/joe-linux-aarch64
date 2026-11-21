build() {
    # No libssh (ssh token) and no asciidoctor; the tarball's ready-made
    # manual pages are installed instead. SELinux does not exist here.
    # OpenSSL is the default crypto back end. OpenSSL 4 supplies Argon2
    # through its KDF API.
    ./configure --prefix=/usr \
        --disable-ssh-token \
        --disable-asciidoc \
        --disable-selinux \
        --with-crypto_backend=openssl \
        --with-tmpfilesdir=/usr/lib/tmpfiles.d
    make
}

package() {
    make DESTDIR="$DESTDIR" install
}
