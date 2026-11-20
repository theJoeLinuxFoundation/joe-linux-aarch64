prepare() {
    # A privileged Python runs only sealed code files; see the patch's header.
    patch -Np1 -i /recipe/joe-sealed-code.patch
}

build() {
    # Profile-guided optimisation (--enable-optimizations) runs part of the test
    # suite during the build, which is slow and not reliable in the build
    # sandbox. It can return once builds are reproducible.
    # There is no system mpdecimal: build _decimal from the bundled copy
    # (the default would silently fall back to the slow pure-Python decimal).
    # _tkinter is left out: it would make every Python installation carry Tk
    # and X11's libraries. The python-tkinter package adds it.
    # linux-gnu, not the driver's Android host: Python's Android mode builds
    # the Python an Android app embeds (sys.platform "android", a platform
    # named after the Android API level, Android's own paths). liblog: Python logs to
    # Android's system log through it when it is embedded in an Android app
    # (bionic's writes to standard error), and configure adds it only for an
    # Android system.
    ac_cv_build=aarch64-unknown-linux-gnu ac_cv_host=aarch64-unknown-linux-gnu \
    ./configure --prefix=/usr \
        LIBS=-llog \
        py_cv_module__tkinter=n/a \
        --enable-shared \
        --with-system-expat \
        --without-system-libmpdec \
        --without-static-libpython
    make
}

package() {
    # "make install" would run ensurepip, which looks at the pip already
    # installed in the build root and, finding the same version there,
    # stages nothing. Install the bundled pip wheel ourselves with
    # --ignore-installed instead; ENSUREPIP_OPTIONS=install gives the same
    # pip3 and pip3.X scripts as "make install" does.
    make DESTDIR="$DESTDIR" ENSUREPIP=no install

    local whl
    whl=$(echo "$PWD"/Lib/ensurepip/_bundled/pip-*.whl)
    ENSUREPIP_OPTIONS=install PIP_CONFIG_FILE=/dev/null \
        LD_LIBRARY_PATH="$PWD${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
        ./python -E "$whl/pip" install --no-cache-dir --no-index --no-deps \
        --ignore-installed --no-user --no-warn-script-location \
        --root "$DESTDIR" "$whl"

    # pip is part of the system Python here: do not nag root and do not
    # look for newer versions of pip.
    install -d "$DESTDIR/etc"
    cat > "$DESTDIR/etc/pip.conf" << EOF2
[global]
root-user-action = ignore
disable-pip-version-check = true
EOF2
}
