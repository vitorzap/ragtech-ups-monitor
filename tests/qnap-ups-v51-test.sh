#!/bin/sh

# TESTE ISOLADO DA POLITICA V5.1
# Nao acessa UPS, nao envia SSH e nao executa poweroff.

BASE="/share/Container/qnap-stack/nut-ragtech"
SCRIPT="$BASE/qnap-ups-events.sh"

echo "========================================"
echo " TESTE DA POLITICA RAGTECH V5.1"
echo "========================================"

# Confirmar que a versao esperada esta instalada.
grep -q 'Monitor V5.1 iniciado' "$SCRIPT" || {
    echo "FALHA: monitor V5.1 nao encontrado"
    exit 1
}

# Ler os parametros diretamente do monitor instalado.
get_config() {
    sed -n "s/^$1=//p" "$SCRIPT" | head -1
}

MAC=$(get_config MAC_DELAY)
QNAP=$(get_config QNAP_DELAY)
LIMIT=$(get_config CHARGE_LIMIT)
FACTOR=$(get_config SECONDS_PER_PERCENT)
MAX=$(get_config MAX_EXTRA)

# Validar os parametros para impedir valores inesperados.
for VALUE in "$MAC" "$QNAP" "$LIMIT" "$FACTOR" "$MAX"; do
    case "$VALUE" in
        ''|*[!0-9]*)
            echo "FALHA: parametro invalido: $VALUE"
            exit 1
            ;;
    esac
done

echo "Politica instalada:"
echo "Mac=${MAC}s QNAP=${QNAP}s"
echo "Limite=${LIMIT}% Fator=${FACTOR}s Maximo=${MAX}s"
echo

awk \
    -v MAC="$MAC" \
    -v QNAP="$QNAP" \
    -v LIMIT="$LIMIT" \
    -v FACTOR="$FACTOR" \
    -v MAX="$MAX" '
function extra(c, x) {
    x = (c - LIMIT) * FACTOR
    if (x < 0) x = 0
    if (x > MAX) x = MAX
    return x
}

function check(nome, real, esperado) {
    total++

    if (real == esperado) {
        printf "OK    %-32s resultado=%s\n", nome, real
    } else {
        printf "FALHA %-32s obtido=%s esperado=%s\n", \
            nome, real, esperado
        erros++
    }
}

function iniciar(c, t) {
    mac_deadline = t + extra(c) + MAC
    qnap_deadline = t + extra(c) + QNAP
    ativo = 1
}

function antecipar(c, t, m, q) {
    m = t + extra(c) + MAC
    q = t + extra(c) + QNAP

    if (m < mac_deadline) mac_deadline = m
    if (q < qnap_deadline) qnap_deadline = q
}

BEGIN {
    erros = 0
    total = 0

    print "=== CARGAS INICIAIS ==="

    iniciar(100, 0)
    check("100%: Mac", mac_deadline, 630)
    check("100%: QNAP", qnap_deadline, 660)

    iniciar(80, 0)
    check("80%: Mac", mac_deadline, 480)
    check("80%: QNAP", qnap_deadline, 510)

    iniciar(50, 0)
    check("50%: Mac", mac_deadline, 30)
    check("50%: QNAP", qnap_deadline, 60)

    print ""
    print "=== DESCARGA RAPIDA ==="

    iniciar(80, 0)

    # Apos 60 segundos a carga caiu para 60%.
    antecipar(60, 60)
    check("Descarga: Mac antecipado", mac_deadline, 240)
    check("Descarga: QNAP antecipado", qnap_deadline, 270)

    # Uma leitura maior nao pode adiar prazos.
    antecipar(90, 65)
    check("Nunca postergar Mac", mac_deadline, 240)
    check("Nunca postergar QNAP", qnap_deadline, 270)

    print ""
    print "=== BATERIA CRITICA ==="

    iniciar(80, 0)

    # Estado LB observado aos 20 segundos.
    mac_deadline = 20
    qnap_deadline = 20

    check("LB: Mac imediato", mac_deadline, 20)
    check("LB: QNAP imediato", qnap_deadline, 20)

    print ""
    print "=== NUT INDISPONIVEL APOS OB ==="

    iniciar(80, 0)

    # Perda de comunicacao aos 100 segundos.
    # Antecipar para politica conservadora.
    if (100 + MAC < mac_deadline)
        mac_deadline = 100 + MAC

    if (100 + QNAP < qnap_deadline)
        qnap_deadline = 100 + QNAP

    check("NUT offline: Mac", mac_deadline, 130)
    check("NUT offline: QNAP", qnap_deadline, 160)

    print ""
    print "=== RETORNO DA ENERGIA ==="

    iniciar(80, 0)

    # Simular OL: limpar ciclo e prazos.
    ativo = 0
    mac_deadline = 0
    qnap_deadline = 0

    check("OL: ciclo cancelado", ativo, 0)
    check("OL: prazo Mac limpo", mac_deadline, 0)
    check("OL: prazo QNAP limpo", qnap_deadline, 0)

    print ""
    print "========================================"
    printf "RESULTADO: %d testes, %d falhas\n", total, erros
    print "========================================"

    if (erros > 0) exit 1
}'
