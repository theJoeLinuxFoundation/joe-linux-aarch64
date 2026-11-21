#!/bin/bash
set -eu
# Remember the last scheduled day across service restarts and shutdowns.
stamp=/var/lib/logrotate.last-run
while :; do
    read -r day hour minute second < <(date '+%F %H %M %S')
    if ((10#$hour < 3)); then
        day=$(date -d "$day 12:00 yesterday" +%F)
    fi
    if [[ ! -f $stamp || $(<"$stamp") < $day ]]; then
        /usr/sbin/logrotate /etc/logrotate.conf
        printf '%s\n' "$day" > "$stamp"
    fi
    # Recheck each local hour so a clock change or resume is picked up.
    sleep "$((3600 - 10#$minute * 60 - 10#$second))"
done
