# Never install this on a real system: it logs root in on the serial console
# without asking for a password. The automated tests drive the system through
# that console, and an image has no other way in until someone sets a
# password. joe-base's serial-getty looks for the marker this ships.
#
# It is a package, not something the image builder writes, so that its files
# are sealed like any others; a root shell would not read an unsealed profile.
package() {
    install -d "$DESTDIR/usr/lib/joe/profile.d"
    echo 'Test image: root is logged in on the serial console.' > "$DESTDIR/usr/lib/joe/test-console"

    # A fixed prompt the test harness can recognise, and no terminal tricks.
    cat > "$DESTDIR/usr/lib/joe/profile.d/test-console.sh" <<'EOT'
case $(tty 2>/dev/null) in
    /dev/ttyAMA*|/dev/ttyS*|/dev/hvc*)
        if [ "$(id -u)" -eq 0 ]; then
            PS1='joe# '
            TERM=dumb
            unset PROMPT_COMMAND
            bind 'set enable-bracketed-paste off' 2>/dev/null
        fi
        ;;
esac
EOT
}
