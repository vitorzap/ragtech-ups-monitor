#!/bin/sh

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 1
. "$SCRIPT_DIR/ups-common.sh"
CONF="$LOG_DIR/upsmon.conf"
LOG="$LOG_DIR/upsmon-service.log"
LOCK="$LOG_DIR/supervisor.lock"

export NUT_CONFPATH="$LOG_DIR"
umask 077

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"
}

# Impede mais de um supervisor
if ! mkdir "$LOCK" 2>/dev/null; then
    OLD_PID=$(cat "$LOCK/pid" 2>/dev/null)

    # Confirma que o PID pertence ao nosso supervisor
    if [ -n "$OLD_PID" ] &&
       [ -r "/proc/$OLD_PID/cmdline" ] &&
       tr '\000' ' ' < "/proc/$OLD_PID/cmdline" |
           grep -q 'qnap-upsmon-start.sh'; then
        log "Supervisor ja esta ativo. PID: $OLD_PID"
        exit 0
    fi

    log "Lock antigo encontrado. Recuperando."

    # Nunca remover lock pertencente a processo desconhecido
    if [ -n "$OLD_PID" ] &&
       kill -0 "$OLD_PID" 2>/dev/null; then
        log "PID ocupado por outro processo. Abortando."
        exit 1
    fi

    rm -f "$LOCK/pid"
    rmdir "$LOCK" 2>/dev/null || exit 1
    mkdir "$LOCK" 2>/dev/null || exit 1
fi

echo "$$" > "$LOCK/pid"
CHILD=""

cleanup() {
    trap '' TERM INT HUP
    log "Encerrando supervisor"

    if [ -n "$CHILD" ]; then
        kill -TERM "$CHILD" 2>/dev/null
        wait "$CHILD" 2>/dev/null
    fi

    rm -f "$LOCK/pid"
    rmdir "$LOCK" 2>/dev/null
    exit 0
}

trap cleanup TERM INT HUP

# Protecao obrigatoria durante os testes
if ! grep -q '^SHUTDOWNCMD "/bin/true"$' "$CONF"; then
    log "ERRO: desligamento simulado nao configurado"
    cleanup
fi

log "Supervisor iniciado. PID $$"
if [ -f "$BASE/qnap-ups-events-watch.sh" ]; then
    /bin/sh "$BASE/qnap-ups-events-watch.sh" </dev/null >/dev/null 2>&1 &
fi

while true; do
    STATUS=$(/sbin/upsc "$UPS" ups.status 2>/dev/null)

    if [ -n "$STATUS" ]; then
        log "NUT disponivel. Estado: $STATUS"

        /usr/sbin/upsmon -D -p >> "$LOG" 2>&1 &
        CHILD=$!

        wait "$CHILD"
        RESULT=$?

        CHILD=""
        log "upsmon terminou. Codigo: $RESULT"
        log "Nova tentativa em 10 segundos"
    else
        log "Servidor NUT indisponivel. Nova tentativa em 10 segundos"
    fi

    sleep 10
done
