prepare() {
    # These manual pages are provided by man-pages.
    find man -name Makefile.in -exec sed -i 's/getspnam\.3 / /' {} \;
    find man -name Makefile.in -exec sed -i 's/passwd\.5 / /' {} \;

    # Hash passwords with yescrypt, keep mailboxes in /var/mail, and leave the
    # /bin and /sbin symlinks out of the default PATH.
    sed -e 's:#ENCRYPT_METHOD SHA512:ENCRYPT_METHOD YESCRYPT:' \
        -e 's:/var/spool/mail:/var/mail:' \
        -e '/PATH=/{s@/sbin:@@;s@/bin:@@}' \
        -i etc/login.defs

    # Authentication goes through PAM, which takes over these settings; left
    # active, they would only produce warnings (Beyond LFS, "Shadow").
    local function
    for function in FAIL_DELAY FAILLOG_ENAB LASTLOG_ENAB MAIL_CHECK_ENAB \
        OBSCURE_CHECKS_ENAB PORTTIME_CHECKS_ENAB QUOTAS_ENAB CONSOLE MOTD_FILE \
        FTMP_FILE NOLOGINS_FILE ENV_HZ PASS_MIN_LEN SU_WHEEL_ONLY \
        PASS_CHANGE_TRIES PASS_ALWAYS_WARN CHFN_AUTH ENCRYPT_METHOD ENVIRON_FILE; do
        sed -i "s/^${function}/# &/" etc/login.defs
    done

    # The subordinate id tools are linked without $(INTLLIBS), as nothing on
    # glibc, whose libc has gettext, notices; on bionic gettext is libintl's.
    grep -q '^@ENABLE_SUBIDS_TRUE@	$(MISCLIBS) -ldl$' src/Makefile.in
    sed -i 's/^@ENABLE_SUBIDS_TRUE@\t$(MISCLIBS) -ldl$/@ENABLE_SUBIDS_TRUE@\t$(MISCLIBS) $(INTLLIBS) -ldl/' src/Makefile.in
}

build() {
    ./configure --sysconfdir=/etc \
        --disable-static \
        --with-bcrypt \
        --with-yescrypt \
        --without-libbsd \
        --disable-logind \
        --with-group-name-max-length=32 \
        --disable-rpath
    make
}

package() {
    # exec_prefix=/usr: configure leaves it empty, which would put login, su,
    # nologin and libsubid in /bin, /sbin and /lib.
    # The set-uid programs get mode 4755 from "make install" itself; nothing
    # is chowned and setcap is not used (no --with-fcaps, no --with-tcb).
    # pamddir=: the PAM files shadow ships do not fit joe's PAM configuration;
    # the ones below, from Beyond LFS, do.
    make exec_prefix=/usr pamddir= DESTDIR="$DESTDIR" install
    make -C man DESTDIR="$DESTDIR" install-man

    install -dm755 "$DESTDIR/etc/pam.d"
    cat > "$DESTDIR/etc/pam.d/login" << "EOF"
# Set failure delay before next prompt to 3 seconds
auth      optional    pam_faildelay.so  delay=3000000

# Check to make sure that the user is allowed to login
auth      requisite   pam_nologin.so

# include system auth settings
auth      include     system-auth

# check access for the user
account   required    pam_access.so

# include system account settings
account   include     system-account

# Set default environment variables for the user
session   required    pam_env.so

# Set resource limits for the user
session   required    pam_limits.so

# include system session and password settings
session   include     system-session
password  include     system-password
EOF
    cat > "$DESTDIR/etc/pam.d/passwd" << "EOF"
password  include     system-password
EOF
    cat > "$DESTDIR/etc/pam.d/su" << "EOF"
# always allow root
auth      sufficient  pam_rootok.so

# include system auth settings
auth      include     system-auth

# include system account settings
account   include     system-account

# Set default environment variables for the service user
session   required    pam_env.so

# include system session settings
session   include     system-session
EOF
    cat > "$DESTDIR/etc/pam.d/chpasswd" << "EOF"
# always allow root
auth      sufficient  pam_rootok.so

# include system auth and account settings
auth      include     system-auth
account   include     system-account
password  include     system-password
EOF
    cp "$DESTDIR/etc/pam.d/chpasswd" "$DESTDIR/etc/pam.d/newusers"
    cat > "$DESTDIR/etc/pam.d/chage" << "EOF"
# always allow root
auth      sufficient  pam_rootok.so

# include system auth and account settings
auth      include     system-auth
account   include     system-account
EOF
    local program
    for program in chfn chgpasswd chsh groupadd groupdel groupmems groupmod useradd userdel usermod; do
        install -m644 "$DESTDIR/etc/pam.d/chage" "$DESTDIR/etc/pam.d/$program"
    done

    # Defaults for useradd: what "useradd -D --gid 999" writes, with the
    # creation of mail spool files turned off. Group 999 is "users".
    install -dm755 "$DESTDIR/etc/default"
    cat > "$DESTDIR/etc/default/useradd" << "EOF"
# useradd defaults file
GROUP=999
GROUPS=
HOME=/home
INACTIVE=-1
EXPIRE=
SHELL=/bin/bash
SKEL=/etc/skel
USRSKEL=/usr/etc/skel
CREATE_MAIL_SPOOL=no
BTRFS_SUBVOLUME_HOME=no
BTRFS_SUBVOLUME_SYSTEM=no
LOG_INIT=yes
EOF
}
