#!/bin/sh

BASE="/share/Container/qnap-stack/nut-ragtech"
LOG="$BASE/qnap-test/ups-events-watch.log"
LOCK="/var/run/qnap-ups-events-watch.lock"

if ! mkdir "$LOCK" 2>/dev/null; then
    exit 0
fi

CHILD=""

cleanup() {
    trap '' TERM INT HUP

    if [ -n "$CHILD" ]; then
        kill -TERM "$CHILD" 2>/dev/null
        wait "$CHILD" 2>/dev/null
    fi

    rmdir "$LOCK" 2>/dev/null
    exit 0
}

trap cleanup TERM INT HUP

while true; do
    # Nao duplicar um monitor ja existente
    if ps | grep '[q]nap-ups-events.sh' |
       grep -v '[q]nap-ups-events-watch' >/dev/null; then
        sleep 10
        continue
    fi

    echo "$(date) Iniciando monitor" >> "$LOG"

    /bin/sh "$BASE/qnap-ups-events.sh" \
        </dev/null >> "$LOG" 2>&1 &

    CHILD=$!
    wait "$CHILD"
    CHILD=""

    echo "$(date) Monitor terminou; reiniciando" >> "$LOG"
    sleep 10
done
