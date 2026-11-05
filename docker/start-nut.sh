#!/bin/sh
set -eu

export NUT_CONFPATH=/etc/nut
export NUT_STATEPATH=/run/nut

UPS_NAME="${UPS_NAME:-ragtech700}"

DRIVER=/opt/nut-install/bin/ragtech
UPSD=/opt/nut-install/sbin/upsd

mkdir -p "$NUT_STATEPATH"

DRIVER_PID=""
UPSD_PID=""

cleanup() {
    trap - TERM INT

    [ -z "$UPSD_PID" ] ||
        kill "$UPSD_PID" 2>/dev/null || true

    [ -z "$DRIVER_PID" ] ||
        kill "$DRIVER_PID" 2>/dev/null || true

    [ -z "$UPSD_PID" ] ||
        wait "$UPSD_PID" 2>/dev/null || true

    [ -z "$DRIVER_PID" ] ||
        wait "$DRIVER_PID" 2>/dev/null || true
}

trap 'exit 0' TERM INT
trap cleanup EXIT

echo "Starting Ragtech driver: $UPS_NAME"

"$DRIVER" -a "$UPS_NAME" -u root -D &
DRIVER_PID=$!

sleep 3

if ! kill -0 "$DRIVER_PID" 2>/dev/null; then
    echo "ERROR: Ragtech driver failed" >&2
    exit 1
fi

echo "Starting NUT server"

"$UPSD" -F -u root &
UPSD_PID=$!

sleep 2

if ! kill -0 "$UPSD_PID" 2>/dev/null; then
    echo "ERROR: NUT server failed" >&2
    exit 1
fi

echo "NUT server started"

while true; do
    if ! kill -0 "$DRIVER_PID" 2>/dev/null; then
        echo "ERROR: Ragtech driver stopped" >&2
        exit 1
    fi

    if ! kill -0 "$UPSD_PID" 2>/dev/null; then
        echo "ERROR: NUT server stopped" >&2
        exit 1
    fi

    sleep 5 &
    wait $! || true
done
