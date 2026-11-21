build() {
    # ACLs of rotated files are kept; there is no SELinux.
    ./configure --prefix=/usr \
        --with-acl \
        --without-selinux
    make
}

package() {
    make DESTDIR="$DESTDIR" install

    # The book's configuration. Its /etc/logrotate.d/sys.log is left out:
    # it rotates the log of sysklogd, and joe sends syslog messages to dynamod-logd.
    install -d "$DESTDIR/etc/logrotate.d"
    cat > "$DESTDIR/etc/logrotate.conf" << "EOF"
# Begin /etc/logrotate.conf

# Rotate log files weekly
weekly

# Don't mail logs to anybody
nomail

# If the log file is empty, it will not be rotated
notifempty

# Number of backups that will be kept
# This will keep the 2 newest backups only
rotate 2

# Create new empty files after rotating old ones
# This will create empty log files, with owner
# set to root, group set to sys, and permissions 664
create 0664 root sys

# Compress the backups with gzip
compress

# No packages own lastlog or wtmp -- rotate them here
/var/log/wtmp {
    missingok
    monthly
    create 0664 root utmp
    rotate 1
}

/var/log/lastlog {
    missingok
    monthly
    rotate 1
}

# Some packages drop log rotation info in this directory
# so we include any file in it.
include /etc/logrotate.d

# End /etc/logrotate.conf
EOF
    chmod 0644 "$DESTDIR/etc/logrotate.conf"

    # The book's optional daily 03:00 timer also catches up after downtime.
    install -Dm755 /recipe/daily.sh "$DESTDIR/usr/lib/logrotate/daily"
    install -Dm644 /recipe/logrotate.toml "$DESTDIR/usr/lib/dynamod/services/logrotate.toml"
}
