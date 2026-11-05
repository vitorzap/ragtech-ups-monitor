#!/bin/sh

LOG="$HOME/Library/Logs/qnap-ups.log"
ENABLED="$HOME/.qnap-ups-shutdown-enabled"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"
}

case "$SSH_ORIGINAL_COMMAND" in
    ups-test)
        log "Teste recebido"
        echo "OK: evento UPS recebido"
        ;;

    ups-shutdown)
        if [ ! -f "$ENABLED" ]; then
            log "Desligamento bloqueado"
            echo "BLOQUEADO"
            exit 1
        fi

        log "Iniciando desligamento seguro"
        sudo -n /sbin/shutdown -h now
        ;;

    *)
        log "Comando nao autorizado"
        exit 1
        ;;
esac
