#!/bin/sh

# Diretório de instalação: local deste script.
BASE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 1

CONFIG_FILE="${UPS_CONFIG_FILE:-$BASE/ups-config.conf}"

if [ ! -r "$CONFIG_FILE" ]; then
    echo "Configuração ausente: $CONFIG_FILE" >&2
    exit 1
fi

. "$CONFIG_FILE"

: "${UPS_NAME:?UPS_NAME não definido}"
: "${NUT_HOST:?NUT_HOST não definido}"
: "${NUT_PORT:?NUT_PORT não definido}"

UPS="${UPS_NAME}@${NUT_HOST}:${NUT_PORT}"

LOG_DIR="$BASE/qnap-test"
mkdir -p "$LOG_DIR" || exit 1
