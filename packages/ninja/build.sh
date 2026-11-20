prepare() {
    # Optional in LFS: let the NINJAJOBS environment variable limit the number
    # of parallel jobs when ninja is run without -j.
    sed -i '/int Guess/a \
  int   j = 0;\
  char* jobs = getenv( "NINJAJOBS" );\
  if ( jobs != NULL ) j = atoi( jobs );\
  if ( j > 0 ) return j;\
' src/ninja.cc
}

build() {
    python3 configure.py --bootstrap --verbose
}

package() {
    install -vDm755 ninja "$DESTDIR/usr/bin/ninja"
    install -vDm644 misc/bash-completion "$DESTDIR/usr/share/bash-completion/completions/ninja"
    install -vDm644 misc/zsh-completion "$DESTDIR/usr/share/zsh/site-functions/_ninja"
}
