#!/usr/bin/env bash
# ==============================================================================
# check-ip.sh — проверка «чистоты» IP-адреса VPS
# ==============================================================================
#
# Назначение:
#   Быстрая проверка IP-адреса на «чистоту» перед использованием в схеме
#   доступа к Claude AI. Проверяет:
#     1. Базовую геолокацию и тип IP (ipinfo.io)
#     2. Наличие в публичных DNSBL (Spamhaus, Barracuda, SORBS, UCEPROTECT)
#     3. Fraud Score через Scamalytics (ссылка — ручная проверка)
#     4. AbuseIPDB (если задан ABUSEIPDB_API_KEY)
#     5. Базовую сетевую доступность (ping, DNS, TCP 443)
#
# Использование:
#   ./check-ip.sh                       # проверка IP по умолчанию (внешний IP хоста)
#   ./check-ip.sh 1.2.3.4               # проверка конкретного IP
#   ABUSEIPDB_API_KEY=xxx ./check-ip.sh # проверка с AbuseIPDB
#   ./check-ip.sh --json                # вывод в JSON (для автоматизации)
#   ./check-ip.sh --no-dnsbl 1.2.3.4    # пропустить DNSBL (быстрее)
#
# Зависимости:
#   bash >= 4.0, curl, dig (или drill/host), awk, grep, sed
#
# Установка зависимостей:
#   Debian/Ubuntu: sudo apt install -y curl dnsutils
#   RHEL/CentOS:   sudo yum install -y curl bind-utils
#   macOS:         brew install curl bind
#
# Лицензия: MIT
# ==============================================================================

set -o pipefail
# set -e отключён намеренно: скрипт продолжает работу при ошибках отдельных проверок

# ------------------------------------------------------------------------------
# Константы и цвета
# ------------------------------------------------------------------------------
readonly SCRIPT_VERSION="1.0.0"
readonly SCRIPT_NAME="$(basename "$0")"

if [[ -t 1 ]]; then
    readonly RED='\033[0;31m'
    readonly GREEN='\033[0;32m'
    readonly YELLOW='\033[1;33m'
    readonly BLUE='\033[0;34m'
    readonly CYAN='\033[0;36m'
    readonly BOLD='\033[1m'
    readonly NC='\033[0m'
else
    readonly RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' NC=''
fi

# ------------------------------------------------------------------------------
# Флаги
# ------------------------------------------------------------------------------
JSON_OUTPUT=false
SKIP_DNSBL=false
SKIP_PING=false
VERBOSE=false
IP=""

# ------------------------------------------------------------------------------
# Счётчики результатов
# ------------------------------------------------------------------------------
WARNINGS=0
FAILURES=0
CHECKS_PASSED=0

# ------------------------------------------------------------------------------
# Вспомогательные функции
# ------------------------------------------------------------------------------
log_info()    { echo -e "${BLUE}[INFO]${NC}  $*" >&2; }
log_ok()      { echo -e "${GREEN}[ OK ]${NC}  $*"; ((CHECKS_PASSED++)); }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; ((WARNINGS++)); }
log_fail()    { echo -e "${RED}[FAIL]${NC}  $*"; ((FAILURES++)); }
log_section() { echo -e "\n${BOLD}${CYAN}▶ $*${NC}"; }

usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [OPTIONS] [IP]

Проверка «чистоты» IP-адреса для схемы доступа к Claude AI.

OPTIONS:
    -h, --help          Показать справку
    -v, --version       Показать версию
    -j, --json          Вывод в JSON
    --no-dnsbl          Пропустить проверку DNSBL (быстрее)
    --no-ping           Пропустить проверку ping
    --verbose           Подробный вывод

ENV:
    ABUSEIPDB_API_KEY   API-ключ AbuseIPDB (опционально, но рекомендуется)
                        Получить бесплатно: https://www.abuseipdb.com/register

EXAMPLES:
    ${SCRIPT_NAME}
    ${SCRIPT_NAME} 1.2.3.4
    ABUSEIPDB_API_KEY=xxx ${SCRIPT_NAME} --json

EXIT CODES:
    0   Все проверки пройдены
    1   Обнаружены предупреждения (WARN)
    2   Обнаружены критические проблемы (FAIL)
    3   Ошибка аргументов / окружения
EOF
}

version() {
    echo "${SCRIPT_NAME} v${SCRIPT_VERSION}"
}

# ------------------------------------------------------------------------------
# Разбор аргументов
# ------------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)    usage; exit 0 ;;
        -v|--version) version; exit 0 ;;
        -j|--json)    JSON_OUTPUT=true ;;
        --no-dnsbl)   SKIP_DNSBL=true ;;
        --no-ping)    SKIP_PING=true ;;
        --verbose)    VERBOSE=true ;;
        -*)
            echo -e "${RED}Неизвестный флаг: $1${NC}" >&2
            usage
            exit 3
            ;;
        *)
            if [[ -n "$IP" ]]; then
                echo -e "${RED}Лишний аргумент: $1${NC}" >&2
                exit 3
            fi
            IP="$1"
            ;;
    esac
    shift
done

# ------------------------------------------------------------------------------
# Проверка окружения
# ------------------------------------------------------------------------------
command -v curl >/dev/null 2>&1 || { echo -e "${RED}Не найден curl.${NC}" >&2; exit 3; }

# Определение dig/host/nslookup
DNS_CMD=""
if command -v dig >/dev/null 2>&1; then
    DNS_CMD="dig +short +time=3 +tries=1"
elif command -v drill >/dev/null 2>&1; then
    DNS_CMD="drill -Q"
elif command -v host >/dev/null 2>&1; then
    DNS_CMD="host -W 3 -t A"
elif command -v nslookup >/dev/null 2>&1; then
    DNS_CMD="nslookup"
else
    echo -e "${YELLOW}Не найден dig/drill/host/nslookup — DNSBL-проверка недоступна.${NC}" >&2
    SKIP_DNSBL=true
fi

# ------------------------------------------------------------------------------
# Получение внешнего IP
# ------------------------------------------------------------------------------
get_public_ip() {
    local ip
    ip=$(curl -s --max-time 10 https://api.ipify.org 2>/dev/null || \
         curl -s --max-time 10 https://ifconfig.me 2>/dev/null || \
         curl -s --max-time 10 https://icanhazip.com 2>/dev/null | tr -d '\n')
    echo "$ip"
}

# Валидация IPv4
validate_ipv4() {
    local ip="$1"
    if [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        local IFS='.'
        for octet in $ip; do
            if ((octet > 255)); then
                return 1
            fi
        done
        return 0
    fi
    return 1
}

# Обратный порядок октетов (для DNSBL)
reverse_ip() {
    local ip="$1"
    echo "$ip" | awk -F. '{print $4"."$3"."$2"."$1}'
}

# ------------------------------------------------------------------------------
# Проверка 1: Геолокация и тип IP (ipinfo.io)
# ------------------------------------------------------------------------------
check_geo() {
    log_section "1. Геолокация и тип IP (ipinfo.io)"

    local response
    response=$(curl -s --max-time 15 "https://ipinfo.io/${IP}/json" 2>/dev/null)

    if [[ -z "$response" ]]; then
        log_fail "Не удалось получить данные от ipinfo.io"
        return 1
    fi

    # Парсинг без jq (используем grep/sed для минимизации зависимостей)
    local city region country org timezone hostname
    city=$(echo "$response"     | grep -oP '"city":\s*"\K[^"]+'      || echo "-")
    region=$(echo "$response"   | grep -oP '"region":\s*"\K[^"]+'    || echo "-")
    country=$(echo "$response"  | grep -oP '"country":\s*"\K[^"]+'   || echo "-")
    org=$(echo "$response"      | grep -oP '"org":\s*"\K[^"]+'       || echo "-")
    timezone=$(echo "$response" | grep -oP '"timezone":\s*"\K[^"]+'  || echo "-")
    hostname=$(echo "$response" | grep -oP '"hostname":\s*"\K[^"]+'  || echo "-")

    echo "  IP:        ${BOLD}${IP}${NC}"
    echo "  Hostname:  ${hostname}"
    echo "  Город:     ${city}, ${region}, ${country}"
    echo "  Организация: ${org}"
    echo "  Timezone:  ${timezone}"
    echo

    # Проверка страны
    case "$country" in
        US|DE|NL|GB|CA|FR|FI|SE|CH|AT|IE|AU|JP|SG)
            log_ok "Страна ${country} — поддерживается Anthropic"
            ;;
        RU|BY|IR|KP|SY|CU)
            log_fail "Страна ${country} — Anthropic не работает. Смените локацию VPS."
            ;;
        *)
            log_warn "Страна ${country} — не в списке рекомендуемых. Проверьте политику Anthropic."
            ;;
    esac

    # Проверка типа организации
    if echo "$org" | grep -qiE "(hosting|datacenter|cloud|vps|server|ovh|hetzner|digitalocean|vultr|linode)"; then
        log_ok "Тип IP: hosting/datacenter — нормально для VPS"
    else
        log_info "Тип IP: не определяется как хостинг (возможно, residential)"
    fi
}

# ------------------------------------------------------------------------------
# Проверка 2: DNSBL
# ------------------------------------------------------------------------------
check_dnsbl() {
    log_section "2. Проверка DNSBL (чёрные списки)"

    if [[ "$SKIP_DNSBL" == "true" ]]; then
        log_info "Пропущено (--no-dnsbl)"
        return 0
    fi

    local rev_ip
    rev_ip=$(reverse_ip "$IP")
    local found=0

    # Формат: "название|зона"
    local -a zones=(
        "Spamhaus ZEN|zen.spamhaus.org"
        "Spamhaus PBL|pbl.spamhaus.org"
        "Spamhaus SBL|sbl.spamhaus.org"
        "Barracuda|b.barracudacentral.org"
        "SORBS|dnsbl.sorbs.net"
        "UCEPROTECT L1|dnsbl-1.uceprotect.net"
        "UCEPROTECT L2|dnsbl-2.uceprotect.net"
        "Composite Blocking List|cbl.abuseat.org"
        "SpamCop|bl.spamcop.net"
        "Mailspike|bl.mailspike.net"
        "JustSpam|dnsbl.justspam.org"
    )

    echo "  Проверяю ${#zones[@]} списков для ${rev_ip}..."
    echo

    for entry in "${zones[@]}"; do
        local name zone query result
        name="${entry%%|*}"
        zone="${entry##*|}"
        query="${rev_ip}.${zone}"

        if [[ "$DNS_CMD" == "nslookup" ]]; then
            result=$(nslookup "$query" 2>/dev/null | grep -E "Address:|Name:" | grep -v "127.0.0.1" | head -1)
        else
            result=$($DNS_CMD "$query" 2>/dev/null)
        fi

        if [[ -n "$result" ]]; then
            # 127.0.0.x — означает «в списке» (x — код причины)
            if echo "$result" | grep -qE "^127\.0\.0\.[2-9]|^127\.0\.0\.1[0-9]"; then
                log_fail "  ${name}: ${RED}В СПИСКЕ${NC} (${result})"
                ((found++))
            else
                echo -e "  ${name}: ${GREEN}чисто${NC}"
            fi
        else
            echo -e "  ${name}: ${GREEN}чисто${NC}"
        fi
    done

    echo
    if ((found > 0)); then
        log_fail "IP найден в ${found} DNSBL. Пересоздайте VPS или запросите delisting."
        return 1
    else
        log_ok "IP не найден ни в одном публичном DNSBL"
    fi
}

# ------------------------------------------------------------------------------
# Проверка 3: Scamalytics (ссылка, ручная проверка)
# ------------------------------------------------------------------------------
check_scamalytics() {
    log_section "3. Fraud Score (Scamalytics)"
    echo "  Автоматический запрос невозможен (нет публичного API)."
    echo "  Проверьте вручную:"
    echo -e "  ${BOLD}${BLUE}https://scamalytics.com/ip/${IP}${NC}"
    echo
    echo "  Интерпретация Fraud Score:"
    echo "    0–30   → низкий риск      ✅"
    echo "    30–74  → средний риск     ⚠️  (мониторьте)"
    echo "    75–100 → высокий риск     ❌ (пересоздайте VPS)"
    echo
    log_info "Ожидаемый Fraud Score: < 30"
}

# ------------------------------------------------------------------------------
# Проверка 4: AbuseIPDB
# ------------------------------------------------------------------------------
check_abuseipdb() {
    log_section "4. AbuseIPDB"

    if [[ -z "$ABUSEIPDB_API_KEY" ]]; then
        log_info "ABUSEIPDB_API_KEY не задан — пропущено."
        echo "  Получить бесплатный ключ: https://www.abuseipdb.com/register"
        echo "  Затем: ABUSEIPDB_API_KEY=xxx ${SCRIPT_NAME} ${IP}"
        return 0
    fi

    local response
    response=$(curl -s --max-time 15 \
        -H "Key: ${ABUSEIPDB_API_KEY}" \
        -H "Accept: application/json" \
        "https://api.abuseipdb.com/api/v2/check?ipAddress=${IP}&maxAgeInDays=90" 2>/dev/null)

    if [[ -z "$response" ]]; then
        log_fail "Не удалось получить данные от AbuseIPDB"
        return 1
    fi

    # Извлечение полей
    local score total_reports country usage_type isp
    score=$(echo "$response"         | grep -oP '"abuseConfidenceScore":\s*\K[0-9]+'   | head -1)
    total_reports=$(echo "$response" | grep -oP '"totalReports":\s*\K[0-9]+'           | head -1)
    country=$(echo "$response"       | grep -oP '"countryCode":\s*"\K[^"]+'           | head -1)
    usage_type=$(echo "$response"    | grep -oP '"usageType":\s*"\K[^"]+'             | head -1)
    isp=$(echo "$response"           | grep -oP '"isp":\s*"\K[^"]+'                   | head -1)

    echo "  Abuse Confidence Score: ${BOLD}${score}%${NC}"
    echo "  Total Reports (90d):    ${total_reports}"
    echo "  Country:                ${country}"
    echo "  Usage Type:             ${usage_type}"
    echo "  ISP:                    ${isp}"
    echo

    if [[ -z "$score" ]]; then
        log_warn "Не удалось распарсить ответ AbuseIPDB"
        return 1
    elif ((score >= 75)); then
        log_fail "Abuse Confidence ${score}% ≥ 75% — IP «грязный». Пересоздайте VPS."
        return 1
    elif ((score >= 25)); then
        log_warn "Abuse Confidence ${score}% — средний риск. Мониторьте."
        return 1
    else
        log_ok "Abuse Confidence ${score}% < 25% — IP чистый."
    fi
}

# ------------------------------------------------------------------------------
# Проверка 5: Сетевая доступность
# ------------------------------------------------------------------------------
check_connectivity() {
    log_section "5. Сетевая доступность"

    # 5.1. Ping
    if [[ "$SKIP_PING" != "true" ]]; then
        if command -v ping >/dev/null 2>&1; then
            local ping_out ping_avg loss
            ping_out=$(ping -c 4 -W 2 "$IP" 2>/dev/null)
            if [[ $? -eq 0 ]]; then
                ping_avg=$(echo "$ping_out" | tail -1 | awk -F'/' '{print $5}')
                loss=$(echo "$ping_out" | grep -oP '\K[0-9]+(?=% packet loss)' || echo "0")
                echo "  Ping: ${ping_avg} ms, потери: ${loss}%"
                if [[ -n "$ping_avg" ]] && (( $(echo "$ping_avg > 300" | bc -l 2>/dev/null || echo 0) )); then
                    log_warn "Ping > 300 ms — возможны проблемы со стримингом. Рассмотрите смену локации."
                else
                    log_ok "Ping в норме"
                fi
            else
                log_warn "Ping не прошёл (ICMP может быть заблокирован — это норма для некоторых хостеров)"
            fi
        else
            log_info "ping не установлен — пропущено"
        fi
    fi

    # 5.2. TCP 443
    if command -v nc >/dev/null 2>&1; then
        if nc -z -w 5 "$IP" 443 2>/dev/null; then
            log_ok "TCP 443 открыт"
        else
            log_fail "TCP 443 закрыт или недоступен"
        fi
    elif command -v timeout >/dev/null 2>&1 && command -v bash >/dev/null 2>&1; then
        if timeout 5 bash -c "echo >/dev/tcp/${IP}/443" 2>/dev/null; then
            log_ok "TCP 443 открыт (через /dev/tcp)"
        else
            log_fail "TCP 443 закрыт или недоступен"
        fi
    else
        log_info "nc и /dev/tcp недоступны — пропущено"
    fi

    # 5.3. DNS-резолвинг
    if [[ -n "$DNS_CMD" && "$DNS_CMD" != "nslookup" ]]; then
        local dns_result
        dns_result=$($DNS_CMD api.anthropic.com 2>/dev/null | head -1)
        if [[ -n "$dns_result" && "$dns_result" =~ ^[0-9] ]]; then
            log_ok "DNS-резолвинг api.anthropic.com работает (${dns_result})"
        else
            log_warn "DNS-резолвинг api.anthropic.com не удался"
        fi
    fi
}

# ------------------------------------------------------------------------------
# Итоговый отчёт
# ------------------------------------------------------------------------------
print_summary() {
    log_section "📊 Итог"

    local total=$((CHECKS_PASSED + WARNINGS + FAILURES))
    echo "  Всего проверок:  ${total}"
    echo -e "  ${GREEN}Пройдено:${NC}      ${CHECKS_PASSED}"
    echo -e "  ${YELLOW}Предупреждений:${NC} ${WARNINGS}"
    echo -e "  ${RED}Провалено:${NC}     ${FAILURES}"
    echo

    if ((FAILURES > 0)); then
        echo -e "${RED}${BOLD}❌ Обнаружены критические проблемы.${NC}"
        echo "   Рекомендация: пересоздайте VPS или смените провайдера."
        return 2
    elif ((WARNINGS > 0)); then
        echo -e "${YELLOW}${BOLD}⚠️  Есть предупреждения.${NC}"
        echo "   Рекомендация: мониторьте ситуацию. При росте проблем — пересоздайте VPS."
        return 1
    else
        echo -e "${GREEN}${BOLD}✅ Все проверки пройдены.${NC}"
        echo "   IP готов к использованию."
        return 0
    fi
}

# ------------------------------------------------------------------------------
# JSON-вывод
# ------------------------------------------------------------------------------
emit_json() {
    local exit_code=$1
    cat <<EOF
{
  "script": "${SCRIPT_NAME}",
  "version": "${SCRIPT_VERSION}",
  "ip": "${IP}",
  "checks": {
    "passed": ${CHECKS_PASSED},
    "warnings": ${WARNINGS},
    "failures": ${FAILURES}
  },
  "result": "$( [[ $exit_code -eq 0 ]] && echo "ok" || ( [[ $exit_code -eq 1 ]] && echo "warn" || echo "fail" ) )"
}
EOF
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
main() {
    echo -e "${BOLD}${CYAN}"
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║         check-ip.sh — проверка «чистоты» IP VPS           ║"
    echo "║                    для Claude AI схемы                     ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    # Определение IP
    if [[ -z "$IP" ]]; then
        log_info "IP не указан — определяю внешний IP хоста..."
        IP=$(get_public_ip)
        if [[ -z "$IP" ]]; then
            echo -e "${RED}Не удалось определить внешний IP. Укажите вручную: ${SCRIPT_NAME} 1.2.3.4${NC}" >&2
            exit 3
        fi
        log_info "Внешний IP: ${IP}"
    fi

    # Валидация
    if ! validate_ipv4 "$IP"; then
        echo -e "${RED}Некорректный IPv4-адрес: ${IP}${NC}" >&2
        exit 3
    fi

    if [[ "$JSON_OUTPUT" != "true" ]]; then
        echo
        echo -e "  Проверяемый IP: ${BOLD}${IP}${NC}"
        echo -e "  Версия скрипта: ${SCRIPT_VERSION}"
        echo -e "  Дата/время:     $(date '+%Y-%m-%d %H:%M:%S %Z')"
    fi

    # Запуск проверок
    check_geo
    check_dnsbl
    check_scamalytics
    check_abuseipdb
    check_connectivity

    # Итог
    print_summary
    local exit_code=$?

    if [[ "$JSON_OUTPUT" == "true" ]]; then
        emit_json "$exit_code"
    fi

    exit "$exit_code"
}

main
