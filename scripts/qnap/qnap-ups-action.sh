#!/bin/sh

# ============================================================
# RAGTECH UPS — CONTROLADOR V5.1
#
# Acoes:
#   mac  -> envia shutdown via SSH
#   qnap -> inicia encerramento seguro do NAS
#
# Mantem o bloqueio de seguranca ja existente.
# ============================================================

BASE="/share/Container/qnap-stack/nut-ragtech"

SSH_DIR="$BASE/ssh"
LOG="$BASE/qnap-test/ups-actions.log"

ENABLED="$BASE/enable-real-shutdown"
OB_MARKER="/var/run/qnap-ragtech-ob-confirmed"

ACTION="$1"

log() {
    printf '%s %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"
}

# Sem autorizacao, executar somente simulacao.
if [ ! -f "$ENABLED" ]; then
    log "$ACTION: simulacao; desligamento bloqueado"
    exit 0
fi

case "$ACTION" in

    mac)
        # Reutiliza chave SSH e receptor do Mac mini.
        # O receptor possui sua propria autorizacao.
        log "MAC: solicitacao de desligamento"

        ssh -i "$SSH_DIR/macmini_ups" \
          -o IdentitiesOnly=yes \
          -o BatchMode=yes \
          -o StrictHostKeyChecking=yes \
          -o UserKnownHostsFile="$SSH_DIR/known_hosts" \
          -o ConnectTimeout=5 \
          -o ConnectionAttempts=1 \
          -o ServerAliveInterval=5 \
          -o ServerAliveCountMax=2 \
          vitor@192.168.15.22 ups-shutdown

        RC=$?

        log "MAC: retorno SSH=$RC"
        exit "$RC"
        ;;

    qnap)
        log "QNAP: solicitacao de desligamento"

        STATUS=$(
            /sbin/upsc ragtech700@127.0.0.1:3493 ups.status \
            2>/dev/null
        )

        ALLOW=0

        case " $STATUS " in

            *" OL "*)
                # Energia normal: nao desligar.
                log "QNAP: cancelado; energia normal"
                exit 1
                ;;

            *" OB "*|*" LB "*)
                # NUT confirma falta de energia.
                ALLOW=1
                ;;

            *)
                # Se o NUT nao responde, aceitar somente
                # uma confirmacao recente de OB.
                if [ -z "$STATUS" ] &&
                   [ -f "$OB_MARKER" ]; then

                    TS=$(cat "$OB_MARKER" 2>/dev/null)
                    NOW=$(date +%s)

                    case "$TS" in

                        ''|*[!0-9]*)
                            log "QNAP: marcador OB invalido"
                            ;;

                        *)
                            AGE=$((NOW - TS))

                            # Marcador expira em 120 segundos.
                            if [ "$AGE" -ge 0 ] &&
                               [ "$AGE" -le 120 ]; then

                                ALLOW=1

                                log \
                                  "QNAP: NUT offline; OB confirmado ha ${AGE}s"
                            fi
                            ;;
                    esac
                fi
                ;;
        esac

        if [ "$ALLOW" -ne 1 ]; then
            log "QNAP: recusado; estado=${STATUS:-OFFLINE}"
            exit 1
        fi

        # Registra antes do comando porque o sistema
        # pode encerrar imediatamente os processos.
        log "QNAP: iniciando desligamento seguro"

        sync

        # Comando ja utilizado na V4 funcional.
        /sbin/poweroff
        exit $?
        ;;

    *)
        echo "Uso: $0 mac|qnap"
        exit 2
        ;;
esac
