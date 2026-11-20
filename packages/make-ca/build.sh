# The second source is Mozilla's root list as shipped in NSS 3.133, the file
# "make-ca -g" would download (from the tip of the same repository) at install
# time. Bump it together with the nss recipe.
CERTDATA=certdata-NSS_3_133_RTM.txt
CERTDATA_REVISION=NSS_3_133_RTM

prepare() {
    # mktemp -t is deprecated and misbehaves when TMPDIR is set.
    sed '/mktemp/s/-t //' -i make-ca
}

build() {
    # Makes the script executable and writes its manual page with the bundled
    # help2man (perl).
    make
}

package() {
    make DESTDIR="$DESTDIR" install
    install -vdm755 "$DESTDIR/etc/ssl/local"

    # No update-pki timer: there is no systemd to run it, and the stores are
    # rebuilt from the root list in this package, which upgrades bring.

    # --- Generate the certificate stores (the book's "make-ca -g") ---------
    # Builds have no network, so the root list comes from $SOURCES. make-ca
    # expects the "# Revision:" line that its own download step adds; without
    # it the build date would end up in /etc/ssl/certdata.txt.
    {
        echo "# Revision:$CERTDATA_REVISION"
        cat "$SOURCES/$CERTDATA"
    } > certdata.txt

    # make-ca writes the anchors to $DESTDIR/etc/pki/anchors and then runs
    # "trust extract" to derive the other stores from them, but the trust
    # module reads the path compiled into p11-kit: /etc/pki/anchors of the
    # build root. Give it a module configuration naming the staged anchors
    # instead (needs p11-kit built with -D env_override_paths=enabled).
    local cfg=$PWD/p11-config
    install -d "$cfg/modules" "$cfg/none" "$cfg/local"
    cat > "$cfg/modules/p11-kit-trust.module" << EOF
module: p11-kit-trust.so
priority: 1
trust-policy: yes
x-init-reserved: paths=$DESTDIR/etc/pki/anchors
EOF

    # --localdir: an empty directory, so that nothing from the build root's
    # /etc/ssl/local is imported.
    P11_PACKAGE_CONFIG_MODULES="$cfg/modules" \
    P11_SYSTEM_CONFIG_MODULES="$cfg/none" \
    P11_SYSTEM_CONFIG_FILE="$cfg/none/pkcs11.conf" \
        ./make-ca --destdir "$DESTDIR" --certdata "$PWD/certdata.txt" \
        --localdir "$cfg/local"

    # The list of anchor checksums is written with $DESTDIR in every path;
    # copy-trust-modifications compares it against /etc/pki/anchors/*.
    sed -i "s|  $DESTDIR/etc/|  /etc/|" "$DESTDIR/etc/pki/anchors.md5sums"

    # make-ca only prints "Failed!!!" when an extraction goes wrong: check
    # that every store really was filled from the staged anchors.
    local anchors certs bundle
    anchors=$(find "$DESTDIR/etc/pki/anchors" -name '*.p11-kit' | wc -l)
    certs=$(find "$DESTDIR/etc/ssl/certs" -name '*.pem' | wc -l)
    bundle=$(grep -c 'BEGIN CERTIFICATE' "$DESTDIR/etc/pki/tls/certs/ca-bundle.crt" 2> /dev/null || true)
    bundle=${bundle:-0}
    echo "make-ca: $anchors anchors, $certs certificates in /etc/ssl/certs, $bundle in ca-bundle.crt"
    if [ "$anchors" -lt 50 ] || [ "$certs" -lt 50 ] || [ "$bundle" -lt 50 ]; then
        echo "make-ca: the certificate stores were not generated" >&2
        return 1
    fi

    # ... and that "trust" reads what the module configuration names rather
    # than the build root's own store: given a directory holding a single
    # anchor file, it must list exactly the certificates in that file.
    local -a files=("$DESTDIR"/etc/pki/anchors/*.p11-kit)
    local want got
    install -d "$cfg/probe-anchors" "$cfg/probe-modules"
    cp "${files[0]}" "$cfg/probe-anchors/"
    sed "s|paths=.*|paths=$cfg/probe-anchors|" "$cfg/modules/p11-kit-trust.module" \
        > "$cfg/probe-modules/p11-kit-trust.module"
    want=$(grep -c 'BEGIN CERTIFICATE' "${files[0]}" || true)
    got=$(P11_PACKAGE_CONFIG_MODULES="$cfg/probe-modules" \
        P11_SYSTEM_CONFIG_MODULES="$cfg/none" \
        P11_SYSTEM_CONFIG_FILE="$cfg/none/pkcs11.conf" \
        trust list --filter=certificates | grep -c '^pkcs11:' || true)
    if [ "$want" -lt 1 ] || [ "$got" != "$want" ]; then
        echo "make-ca: trust ignores P11_PACKAGE_CONFIG_MODULES (listed $got certificates, expected $want);" >&2
        echo "make-ca: p11-kit must be built with -D env_override_paths=enabled" >&2
        return 1
    fi

    if grep -q "$DESTDIR" "$DESTDIR/etc/pki/anchors.md5sums"; then
        echo "make-ca: anchors.md5sums still names the staging directory" >&2
        return 1
    fi
    # (objsign-ca-bundle.crt is legitimately empty: Mozilla's list no longer
    # carries code-signing trust.)
    test -s "$DESTDIR/etc/pki/tls/certs/email-ca-bundle.crt"
    test -s "$DESTDIR/etc/pki/tls/java/cacerts"
    test -s "$DESTDIR/etc/ssl/certdata.txt"

    # Let pip use the system store instead of its vendored copy of certifi.
    install -vdm755 "$DESTDIR/etc/profile.d"
    cat > "$DESTDIR/etc/profile.d/pythoncerts.sh" << "EOF"
# Begin /etc/profile.d/pythoncerts.sh

export _PIP_STANDALONE_CERT=/etc/pki/tls/certs/ca-bundle.crt

# End /etc/profile.d/pythoncerts.sh
EOF
}
