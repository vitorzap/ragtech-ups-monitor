#!/bin/sh

# ============================================================
# RAGTECH UPS - MONITOR V5.2
#
# Politica adaptativa baseada em battery.charge.
#
# Melhorias V5.2:
# 1. Horarios de desligamento legiveis.
# 2. Taxa de descarga observada apos estabilizacao.
# 3. Taxa utilizada apenas para antecipar desligamentos.
# 4. Historico persistente limitado a 50 eventos.
#
# Mantem:
# - SSH nao bloqueante para o Mac mini.
# - Repeticao de tentativas SSH.
# - Desligamento independente do QNAP.
# - Protecao para perda do NUT apos OB confirmado.
# ============================================================

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 1
. "$SCRIPT_DIR/ups-common.sh"

LOG="$BASE/qnap-test/ups-events.log"
HISTORY="$BASE/qnap-test/ups-history.txt"
OB_MARKER="/var/run/qnap-ragtech-ob-confirmed"

# Politica basica
: "${MAC_DELAY:=30}"
: "${QNAP_DELAY:=60}"

# Politica adaptativa
: "${CHARGE_LIMIT:=50}"
: "${SECONDS_PER_PERCENT:=15}"
: "${MAX_EXTRA:=600}"

# Amostragem da bateria
: "${STABILIZATION:=90}"
: "${MIN_SAMPLE_SECONDS:=60}"
: "${MIN_SAMPLE_DROP:=2}"

# Usar apenas 50% do tempo calculado ate 50% de carga.
: "${RATE_SAFETY_PERCENT:=50}"

: "${INTERVAL:=5}"
: "${RETRY_INTERVAL:=10}"
: "${MAC_TIMEOUT:=30}"

# Estado da interrupcao
START_OB=""
MAC_DEADLINE=0
QNAP_DEADLINE=0

MAC_DONE=0
MAC_PENDING=0
MAC_PENDING_SINCE=0
MAC_RESULT=""
MAC_ATTEMPT=0
LAST_MAC_TRY=0

QNAP_DONE=0
LAST_QNAP_TRY=0

PREVIOUS=""
OFFLINE_HANDLED=0
LB_RECORDED=0
LAST_CHARGE_RECORDED=-1

# Estado da medicao de descarga
RATE_START_T=0
RATE_START_C=-1
RATE_CENTI=0

mkdir -p "$BASE/qnap-test" || exit 1

log() {
    printf '%s %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"
}

has_flag() {
    case " $1 " in
        *" $2 "*) return 0 ;;
        *) return 1 ;;
    esac
}

# Ler a porcentagem de bateria.
# Retornar -1 se a leitura for invalida.
get_charge() {
    /sbin/upsc "$UPS" battery.charge 2>/dev/null |
    awk '
        /^[0-9]+([.][0-9]+)?$/ && $1>=0 && $1<=100 {
            printf "%d\n", $1
            valid=1
            exit
        }
        END {
            if (!valid) print -1
        }
    '
}

# Converter um timestamp Unix em horario local legivel.
format_time() {
    date -d "@$1" '+%Y-%m-%d %H:%M:%S'
}

# Historico operacional:
# data/hora, evento, bateria no momento e tempo decorrido.
history_event() {
    EVENT="$1"
    DETAILS="$2"

    EVENT_NOW=$(date +%s)
    EVENT_CHARGE=$(get_charge)

    if [ "$EVENT_CHARGE" -ge 0 ]; then
        BATTERY_TEXT="${EVENT_CHARGE}%"
    else
        BATTERY_TEXT="N/D"
    fi

    if [ -n "$START_OB" ]; then
        ELAPSED=$((EVENT_NOW - START_OB))
        [ "$ELAPSED" -ge 0 ] || ELAPSED=0

        TIME_TEXT=$(printf 'T+%02d:%02d' \
            "$((ELAPSED / 60))" \
            "$((ELAPSED % 60))")
    else
        TIME_TEXT="T+--:--"
    fi

    printf '%s | %-26s | bateria=%-4s | %s | %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" \
        "$EVENT" \
        "$BATTERY_TEXT" \
        "$TIME_TEXT" \
        "$DETAILS" >> "$HISTORY"

    TMP="${HISTORY}.$$"

    if tail -n 50 "$HISTORY" > "$TMP"; then
        mv -f "$TMP" "$HISTORY"
    else
        rm -f "$TMP"
    fi
}

# Espera adicional calculada conforme a carga.
calc_extra() {
    C="$1"

    if [ "$C" -le "$CHARGE_LIMIT" ]; then
        echo 0
        return
    fi

    EXTRA=$(( (C - CHARGE_LIMIT) * SECONDS_PER_PERCENT ))

    [ "$EXTRA" -le "$MAX_EXTRA" ] || EXTRA="$MAX_EXTRA"

    echo "$EXTRA"
}

# Registrar novos horarios somente quando houver uma
# antecipacao acumulada relevante (30s ou mais).
# Os prazos internos sao sempre atualizados.
anticipate_deadlines() {
    NEW_MAC="$1"
    NEW_QNAP="$2"
    REASON="$3"

    if [ "$NEW_MAC" -lt "$MAC_DEADLINE" ]; then
        OLD="$MAC_DEADLINE"
        MAC_DEADLINE="$NEW_MAC"

        if [ $((OLD - NEW_MAC)) -ge 30 ]; then
            history_event "MAC_DEADLINE_EARLIER" \
                "novo=$(format_time "$MAC_DEADLINE") motivo=$REASON"
        fi
    fi

    if [ "$NEW_QNAP" -lt "$QNAP_DEADLINE" ]; then
        OLD="$QNAP_DEADLINE"
        QNAP_DEADLINE="$NEW_QNAP"

        if [ $((OLD - NEW_QNAP)) -ge 30 ]; then
            history_event "QNAP_DEADLINE_EARLIER" \
                "novo=$(format_time "$QNAP_DEADLINE") motivo=$REASON"
        fi
    fi
}

# ============================================================
# MEDICAO DA TAXA DE DESCARGA
#
# Ignorar os primeiros 90 segundos.
#
# Depois, medir uma janela de pelo menos 60 segundos.
# Exigir queda de pelo menos 2 pontos percentuais.
#
# Taxa armazenada em centesimos de ponto percentual/min.
# Exemplo: RATE_CENTI=200 significa 2.00%/min.
#
# A taxa nunca aumenta os prazos existentes.
# ============================================================
update_discharge_rate() {
    C="$1"

    [ "$C" -ge 0 ] || return
    [ -n "$START_OB" ] || return

    ELAPSED=$((NOW - START_OB))

    # Periodo inicial: nao calcular taxa.
    if [ "$ELAPSED" -lt "$STABILIZATION" ]; then
        return
    fi

    # Primeira amostra depois da estabilizacao.
    if [ "$RATE_START_T" -eq 0 ]; then
        RATE_START_T="$NOW"
        RATE_START_C="$C"

        history_event "RATE_BASELINE" \
            "inicio_da_medicao carga=${C}%"
        return
    fi

    SAMPLE_SECONDS=$((NOW - RATE_START_T))

    [ "$SAMPLE_SECONDS" -ge "$MIN_SAMPLE_SECONDS" ] || return

    # Uma oscilacao positiva sugere reajuste da estimativa.
    # Reiniciar a janela, sem ampliar os prazos.
    if [ "$C" -gt "$RATE_START_C" ]; then
        RATE_START_T="$NOW"
        RATE_START_C="$C"

        history_event "RATE_REBASELINE" \
            "leitura_subiu; nova_base=${C}%"
        return
    fi

    DROP=$((RATE_START_C - C))

    # Aguardar uma queda mensuravel.
    if [ "$DROP" -lt "$MIN_SAMPLE_DROP" ]; then
        return
    fi

    # Formula:
    # taxa (%/min) = queda * 60 / duracao
    # Multiplicamos por 100 para usar aritmetica inteira.
    RATE_CENTI=$((DROP * 6000 / SAMPLE_SECONDS))

    [ "$RATE_CENTI" -gt 0 ] || RATE_CENTI=1

    RATE_INT=$((RATE_CENTI / 100))
    RATE_DEC=$((RATE_CENTI % 100))

    RATE_TEXT=$(printf '%d.%02d' "$RATE_INT" "$RATE_DEC")

    history_event "DISCHARGE_RATE" \
        "taxa=${RATE_TEXT}%/min janela=${SAMPLE_SECONDS}s queda=${DROP}pp"

    log "V5.2: taxa observada=${RATE_TEXT}%/min"

    # Estimar o tempo ate a reserva de 50%.
    # Nao e uma autonomia garantida.
    REMAINING_PP=$((C - CHARGE_LIMIT))

    if [ "$REMAINING_PP" -le 0 ]; then
        SAFE_SECONDS=0
    else
        ESTIMATED_SECONDS=$((REMAINING_PP * 6000 / RATE_CENTI))

        # Utilizar apenas metade desse tempo.
        SAFE_SECONDS=$((ESTIMATED_SECONDS * RATE_SAFETY_PERCENT / 100))
    fi

    # Usar a taxa apenas para antecipar, nunca adiar.
    anticipate_deadlines \
        "$((NOW + SAFE_SECONDS + MAC_DELAY))" \
        "$((NOW + SAFE_SECONDS + QNAP_DELAY))" \
        "taxa_observada"

    # Iniciar nova janela de medicao.
    RATE_START_T="$NOW"
    RATE_START_C="$C"
}

# ============================================================
# MAC MINI - SSH ASSINCRONO COM NOVAS TENTATIVAS
# ============================================================
check_mac_result() {
    [ "$MAC_PENDING" -eq 1 ] || return

    if [ -f "$MAC_RESULT" ]; then
        RC=$(cat "$MAC_RESULT" 2>/dev/null)
        rm -f "$MAC_RESULT"

        MAC_PENDING=0

        if [ "$RC" = "0" ]; then
            MAC_DONE=1
            history_event "MAC_SSH_ACCEPTED" "retorno=0"
        else
            history_event "MAC_SSH_FAILED" \
                "retorno=${RC:-N/D}"
        fi

    elif [ $((NOW - MAC_PENDING_SINCE)) -ge "$MAC_TIMEOUT" ]; then
        MAC_PENDING=0

        history_event "MAC_SSH_TIMEOUT" \
            "limite=${MAC_TIMEOUT}s"
    fi
}

send_mac() {
    LAST_MAC_TRY="$NOW"
    MAC_PENDING=1
    MAC_PENDING_SINCE="$NOW"

    MAC_ATTEMPT=$((MAC_ATTEMPT + 1))

    MAC_RESULT="$BASE/qnap-test/.ups-mac-${START_OB}-${MAC_ATTEMPT}.result"

    rm -f "$MAC_RESULT"

    history_event "MAC_SHUTDOWN_REQUESTED" \
        "tentativa=$MAC_ATTEMPT"

    (
        "$BASE/qnap-ups-action.sh" mac
        RC=$?
        printf '%s\n' "$RC" > "$MAC_RESULT"
    ) </dev/null >>"$BASE/qnap-test/ups-actions.log" 2>&1 &
}

# ============================================================
# QNAP - DESLIGAMENTO NORMAL
# ============================================================
send_qnap() {
    LAST_QNAP_TRY="$NOW"

    # Registrar antes do poweroff.
    history_event "QNAP_SHUTDOWN_REQUESTED" \
        "previsto=$(format_time "$QNAP_DEADLINE")"

    if "$BASE/qnap-ups-action.sh" qnap; then
        QNAP_DONE=1
        log "V5.2: controlador QNAP retornou sucesso"
    else
        history_event "QNAP_COMMAND_FAILED" \
            "nova_tentativa_em_10s"
    fi
}

# Limpar dados de um ciclo encerrado.
reset_cycle() {
    START_OB=""
    MAC_DEADLINE=0
    QNAP_DEADLINE=0

    MAC_DONE=0
    MAC_PENDING=0
    MAC_PENDING_SINCE=0
    MAC_ATTEMPT=0
    LAST_MAC_TRY=0

    QNAP_DONE=0
    LAST_QNAP_TRY=0

    OFFLINE_HANDLED=0
    LB_RECORDED=0
    LAST_CHARGE_RECORDED=-1

    RATE_START_T=0
    RATE_START_C=-1
    RATE_CENTI=0

    rm -f "$OB_MARKER"
}

mark_ob() {
    printf '%s\n' "$NOW" > "$OB_MARKER"
}

# ============================================================
# INICIALIZACAO
# ============================================================
INITIAL_STATUS=$(/sbin/upsc "$UPS" ups.status 2>/dev/null)

if has_flag "$INITIAL_STATUS" OL; then
    rm -f "$OB_MARKER"
fi

log "Monitor V5.2 iniciado"
history_event "MONITOR_V5_2_STARTED" "monitor_ativo"

trap 'log "Monitor V5.2 encerrado"; exit 0' TERM INT

# ============================================================
# LOOP PRINCIPAL
# ============================================================
while true; do
    NOW=$(date +%s)

    STATUS=$(/sbin/upsc "$UPS" ups.status 2>/dev/null)
    [ -n "$STATUS" ] || STATUS="OFFLINE"

    if [ "$STATUS" != "$PREVIOUS" ]; then
        log "ESTADO: ${PREVIOUS:-INICIAL} -> $STATUS"
        PREVIOUS="$STATUS"
    fi

    check_mac_result

    # --------------------------------------------------------
    # ENERGIA NORMAL
    # --------------------------------------------------------
    if has_flag "$STATUS" OL; then

        if [ -n "$START_OB" ]; then
            history_event "POWER_RESTORED" \
                "acoes_pendentes_canceladas"
        fi

        reset_cycle

    # --------------------------------------------------------
    # FALTA DE ENERGIA
    # --------------------------------------------------------
    elif has_flag "$STATUS" OB; then

        mark_ob
        OFFLINE_HANDLED=0

        CHARGE=$(get_charge)

        if [ -z "$START_OB" ]; then
            START_OB="$NOW"

            EXTRA=0

            if [ "$CHARGE" -ge 0 ]; then
                EXTRA=$(calc_extra "$CHARGE")
                LAST_CHARGE_RECORDED="$CHARGE"
            fi

            MAC_DEADLINE=$((NOW + EXTRA + MAC_DELAY))
            QNAP_DEADLINE=$((NOW + EXTRA + QNAP_DELAY))

            history_event "POWER_LOST" \
                "espera_extra=${EXTRA}s"

            history_event "SHUTDOWN_SCHEDULED" \
                "Mac=$(format_time "$MAC_DEADLINE") QNAP=$(format_time "$QNAP_DEADLINE")"

        else
            # Ajuste por carga instantanea.
            if [ "$CHARGE" -ge 0 ]; then
                EXTRA=$(calc_extra "$CHARGE")

                anticipate_deadlines \
                    "$((NOW + EXTRA + MAC_DELAY))" \
                    "$((NOW + EXTRA + QNAP_DELAY))" \
                    "carga_atual"

                # Nova medicao de taxa, apos estabilizacao.
                update_discharge_rate "$CHARGE"

                if [ "$LAST_CHARGE_RECORDED" -ge 0 ] &&
                   [ $((LAST_CHARGE_RECORDED - CHARGE)) -ge 5 ]; then

                    history_event "BATTERY_DECREASED" \
                        "carga_atual=${CHARGE}%"

                    LAST_CHARGE_RECORDED="$CHARGE"
                fi

            else
                # Leitura invalida elimina espera prolongada.
                anticipate_deadlines \
                    "$((NOW + MAC_DELAY))" \
                    "$((NOW + QNAP_DELAY))" \
                    "leitura_invalida"
            fi
        fi

        # LB: antecipacao de emergencia.
        if has_flag "$STATUS" LB; then
            MAC_DEADLINE="$NOW"
            QNAP_DEADLINE="$NOW"

            if [ "$LB_RECORDED" -eq 0 ]; then
                history_event "BATTERY_CRITICAL" \
                    "desligamento_imediato"
                LB_RECORDED=1
            fi
        fi

    # --------------------------------------------------------
    # FALHA NUT APOS FALTA CONFIRMADA
    # --------------------------------------------------------
    elif [ "$STATUS" = "OFFLINE" ]; then

        if [ -n "$START_OB" ] &&
           [ "$OFFLINE_HANDLED" -eq 0 ]; then

            history_event "NUT_OFFLINE" \
                "aplicando_prazos_conservadores"

            anticipate_deadlines \
                "$((NOW + MAC_DELAY))" \
                "$((NOW + QNAP_DELAY))" \
                "NUT_offline"

            OFFLINE_HANDLED=1
        fi
    fi

    # --------------------------------------------------------
    # EXECUTAR DESLIGAMENTOS
    # --------------------------------------------------------
    if [ -n "$START_OB" ] &&
       { has_flag "$STATUS" OB ||
         [ "$STATUS" = "OFFLINE" ]; }; then

        if [ "$MAC_DONE" -eq 0 ] &&
           [ "$MAC_PENDING" -eq 0 ] &&
           [ "$NOW" -ge "$MAC_DEADLINE" ] &&
           { [ "$LAST_MAC_TRY" -eq 0 ] ||
             [ $((NOW - LAST_MAC_TRY)) -ge "$RETRY_INTERVAL" ]; }; then

            send_mac
        fi

        if [ "$QNAP_DONE" -eq 0 ] &&
           [ "$NOW" -ge "$QNAP_DEADLINE" ] &&
           { [ "$LAST_QNAP_TRY" -eq 0 ] ||
             [ $((NOW - LAST_QNAP_TRY)) -ge "$RETRY_INTERVAL" ]; }; then

            send_qnap
        fi
    fi

    sleep "$INTERVAL"
done
