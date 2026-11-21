prepare() {
    # libxcrypt has better pages for the password hashing functions.
    rm -v man3/crypt*
}

package() {
    # -R: the makefiles break with make's built-in variables. GIT=false: the
    # tarball is not a git checkout.
    make -R GIT=false prefix=/usr DESTDIR="$DESTDIR" install
}
