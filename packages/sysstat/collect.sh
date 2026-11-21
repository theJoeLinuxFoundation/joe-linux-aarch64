#!/bin/bash
# The boot record tells sar when kernel counters were reset. Restarting the
# service in the same boot must not insert another one.
if [[ ! -e /run/sysstat-boot ]]; then
    /usr/lib/sa/sa1 --boot && touch /run/sysstat-boot || exit 1
fi

# Follow upstream's collect, rotate and summary timers in local time.
while :; do
    minute=$(date +%H:%M)
    case "$minute" in
        00:00) /usr/lib/sa/sa1 --rotate ;;
        00:07) /usr/lib/sa/sa2 -A & ;;
    esac
    case "$minute" in
        *0) /usr/lib/sa/sa1 1 1 ;;
    esac
    sleep "$((60 - 10#$(date +%S)))"
done
