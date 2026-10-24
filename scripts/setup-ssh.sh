#!/usr/bin/env bash
# ==============================================================================
# setup-ssh.sh — харденинг SSH, создание пользователя, firewall и fail2ban
# ==============================================================================
#
# Назначение:
#   Автоматизирует шаги 1.3.4–1.3.11 из vps-setup.md:
#     1. Создание пользователя pilot с sudo
#     2. Копирование SSH-ключа из authorized_keys root
#     3. Харденинг /etc/ssh/sshd_config (порт, отключение root/password auth)
#     4. Настройка fail2ban
#     5. Настройка ufw (firewall)
#     6. Включение автообновлений безопасности
#     7. Оптимизация sysctl (BBR, TCP tuning)
#
# ⚠️  КРИТИЧЕСКИ ВАЖНО:
#     Этот скрипт может ОТКЛЮЧИТЬ вам доступ к серверу, если запустить его
#     без предварительно добавленного SSH-ключа. Скрипт делает бэкап конфига
#     и предлагает план отката, но НЕ МОЖЕТ восстановить доступ, если ключа нет.
#
#     ПЕРЕД ЗАПУСКОМ убедитесь:
#       - У вас есть SSH-ключ на локальном ПК (~/.ssh/id_ed25519_*)
#       - Вы скопировали публичный ключ на сервер (root@ или ваш пользователь)
#       - У вас есть доступ к веб-консоли провайдера (VNC/KVM) как аварийный канал
#
# Использование:
#   sudo ./setup-ssh.sh                          # интерактивный режим
#   sudo ./setup-ssh.sh --port 1337              # свой SSH-порт
#   sudo ./setup-ssh.sh --user pilot             # своё имя пользователя
#   sudo ./setup-ssh.sh --dry-run                # только показать план
#   sudo ./setup-ssh.sh --rollback               # откатить изменения
#   sudo ./setup-ssh.sh --skip-firewall          # пропустить ufw
#   sudo ./setup-ssh.sh --skip-fail2ban          # пропустить fail2ban
#   sudo ./setup-ssh.sh --skip-sysctl            # пропустить sysctl
#
# Зависимости:
#   bash >= 4.0, sshd, ufw, fail2ban, openssh-server (уже должны быть в системе)
#
# Лицензия: MIT
# ==============================================================================

set -o pipefail
# set -e отключён: скрипт обрабатывает ошибки индивидуально, чтобы не оставить
# систему в промежуточном состоянии при сбое одной проверки

readonly SCRIPT_VERSION="1.0.0"
readonly SCRIPT_NAME="$(basename "$0")"
readonly BACKUP_DIR="/root/.ssh-hardening-backup-$(date +%Y%m%d-%H%M%S)"
readonly SSHD_CONFIG="/etc/ssh/sshd_config"
readonly SSH_PORT_DEFAULT="1337"
readonly USER_DEFAULT="pilot"

# Цвета
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

# Флаги
DRY_RUN=false
ROLLBACK=false
SKIP_FIREWALL=false
SKIP_FAIL2BAN=false
SKIP_SYSCTL=false
SSH_PORT=""
TARGET_USER=""

# Счётчики
WARNINGS=0
FAILURES=0
STEPS_DONE=0

# ------------------------------------------------------------------------------
# Вспомогательные функции
# ------------------------------------------------------------------------------
log_info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()      { echo -e "${GREEN}[ OK ]${NC}  $*"; ((STEPS_DONE++)); }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; ((WARNINGS++)); }
log_fail()    { echo -e "${RED}[FAIL]${NC}  $*"; ((FAILURES++)); }
log_section() { echo -e "\n${BOLD}${CYAN}▶ $*${NC}"; }
log_cmd()     { echo -e "  ${CYAN}$ ${NC}$*"; }

# Выполнить или показать (для dry-run)
run() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_cmd "$*"
    else
        log_cmd "$*"
        "$@"
    fi
}

# Записать файл или показать (для dry-run)
write_file() {
    local path="$1"
    local content="$2"
    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "  ${CYAN}[dry-run] ${NC}записать в ${path}:"
        echo "$content" | sed 's/^/    /'
    else
        echo "$content" > "$path"
        log_ok "Записан ${path}"
    fi
}

usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [OPTIONS]

Харденинг SSH и базовая защита VPS для схемы Claude AI.

OPTIONS:
    -h, --help              Справка
    -v, --version           Версия
    --port PORT             SSH-порт (по умолчанию: ${SSH_PORT_DEFAULT})
    --user NAME             Имя пользователя (по умолчанию: ${USER_DEFAULT})
    --dry-run               Показать план без изменений
    --rollback              Откатить изменения из последнего бэкапа
    --skip-firewall         Пропустить настройку ufw
    --skip-fail2ban         Пропустить настройку fail2ban
    --skip-sysctl           Пропустить настройку sysctl

SAFETY:
    Перед изменением sshd_config скрипт:
      1. Проверяет, что у root есть authorized_keys
      2. Делает бэкап конфига
      3. Проверяет синтаксис через sshd -t
      4. Требует подтверждения пользователя (если не --dry-run)

    Если что-то пойдёт не так — используйте:
      sudo ./${SCRIPT_NAME} --rollback
      или веб-консоль провайдера (VNC/KVM)

EXAMPLES:
    sudo ./${SCRIPT_NAME} --dry-run
    sudo ./${SCRIPT_NAME} --port 2222 --user admin
    sudo ./${SCRIPT_NAME} --rollback
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
        -h|--help)         usage; exit 0 ;;
        -v|--version)      version; exit 0 ;;
        --port)            SSH_PORT="$2"; shift 2 ;;
        --user)            TARGET_USER="$2"; shift 2 ;;
        --dry-run)         DRY_RUN=true; shift ;;
        --rollback)        ROLLBACK=true; shift ;;
        --skip-firewall)   SKIP_FIREWALL=true; shift ;;
        --skip-fail2ban)   SKIP_FAIL2BAN=true; shift ;;
        --skip-sysctl)     SKIP_SYSCTL=true; shift ;;
        *)
            echo -e "${RED}Неизвестный аргумент: $1${NC}" >&2
            usage
            exit 3
            ;;
    esac
done

SSH_PORT="${SSH_PORT:-$SSH_PORT_DEFAULT}"
TARGET_USER="${TARGET_USER:-$USER_DEFAULT}"

# ------------------------------------------------------------------------------
# Проверка root
# ------------------------------------------------------------------------------
if [[ "$EUID" -ne 0 ]]; then
    echo -e "${RED}Скрипт должен запускаться от root (sudo).${NC}" >&2
    exit 3
fi

# ------------------------------------------------------------------------------
# Rollback
# ------------------------------------------------------------------------------
do_rollback() {
    log_section "🔄 Откат изменений"

    local latest_backup
    latest_backup=$(ls -dt /root/.ssh-hardening-backup-* 2>/dev/null | head -1)

    if [[ -z "$latest_backup" ]]; then
        log_fail "Бэкап не найден в /root/.ssh-hardening-backup-*"
        exit 2
    fi

    log_info "Использую бэкап: ${latest_backup}"
    log_info "Содержимое:"
    ls -la "$latest_backup"
    echo

    if [[ -f "${latest_backup}/sshd_config" ]]; then
        log_info "Восстанавливаю ${SSHD_CONFIG}..."
        cp "${latest_backup}/sshd_config" "${SSHD_CONFIG}"
        sshd -t && systemctl restart ssh
        log_ok "sshd_config восстановлен"
    fi

    if [[ -f "${latest_backup}/ufw.rules" ]]; then
        log_info "Восстанавливаю правила ufw..."
        # Сброс и повторное применение из бэкапа — упрощённо
        log_warn "Правила ufw требуют ручного восстановления. Содержимое:"
        cat "${latest_backup}/ufw.rules"
    fi

    log_section "✅ Откат завершён"
    log_info "Проверьте доступ по SSH на старом порту: ssh root@<IP>"
    exit 0
}

if [[ "$ROLLBACK" == "true" ]]; then
    do_rollback
fi

# ------------------------------------------------------------------------------
# Предварительные проверки
# ------------------------------------------------------------------------------
log_section "0. Предварительные проверки"

command -v sshd >/dev/null 2>&1 || { log_fail "sshd не установлен"; exit 3; }
command -v systemctl >/dev/null 2>&1 || { log_fail "systemctl не найден (не systemd?)"; exit 3; }

if [[ ! -f "$SSHD_CONFIG" ]]; then
    log_fail "Не найден ${SSHD_CONFIG}"
    exit 3
fi

# Проверка, что у root есть authorized_keys (иначе после харденинга потеряем доступ)
ROOT_AUTH_KEYS="/root/.ssh/authorized_keys"
if [[ ! -s "$ROOT_AUTH_KEYS" ]]; then
    log_fail "У root нет SSH-ключей в ${ROOT_AUTH_KEYS}"
    log_fail "Отключение пароля заблокирует доступ. Добавьте ключ и повторите."
    log_info "С вашего ПК: ssh-copy-id root@<IP>"
    exit 2
fi

KEY_COUNT=$(grep -cE '^(ssh-|ecdsa-)' "$ROOT_AUTH_KEYS" 2>/dev/null || echo 0)
log_ok "У root найдено ${KEY_COUNT} SSH-ключей"

# Проверка валидности целевого пользователя (не root, не системный)
if [[ "$TARGET_USER" == "root" ]]; then
    log_fail "Нельзя использовать 'root' как целевого пользователя"
    exit 3
fi
if [[ "$TARGET_USER" =~ ^(root|daemon|bin|sys|sync|games|man|lp|mail|news|uucp|proxy|www-data|backup|list|irc|_apt|nobody)$ ]]; then
    log_fail "Имя '${TARGET_USER}' зарезервировано системой"
    exit 3
fi

# Проверка валидности порта
if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || ((SSH_PORT < 1 || SSH_PORT > 65535)); then
    log_fail "Некорректный порт: ${SSH_PORT}"
    exit 3
fi
log_ok "Порт ${SSH_PORT} валиден"

# ------------------------------------------------------------------------------
# Подтверждение
# ------------------------------------------------------------------------------
echo
echo -e "${YELLOW}${BOLD}⚠️  ВНИМАНИЕ! Скрипт изменит конфигурацию SSH.${NC}"
echo -e "${YELLOW}    Убедитесь, что у вас есть:${NC}"
echo -e "${YELLOW}      1. SSH-ключ на локальном ПК${NC}"
echo -e "${YELLOW}      2. Доступ к веб-консоли провайдера (VNC/KVM)${NC}"
echo
echo "  Целевой пользователь: ${BOLD}${TARGET_USER}${NC}"
echo "  SSH-порт:             ${BOLD}${SSH_PORT}${NC}"
echo "  Dry-run:              ${DRY_RUN}"
echo

if [[ "$DRY_RUN" != "true" ]]; then
    read -r -p "Продолжить? (введите YES для подтверждения): " confirm
    if [[ "$confirm" != "YES" ]]; then
        echo "Отменено."
        exit 0
    fi
fi

# ------------------------------------------------------------------------------
# Бэкап
# ------------------------------------------------------------------------------
log_section "1. Бэкап текущей конфигурации"

if [[ "$DRY_RUN" != "true" ]]; then
    mkdir -p "$BACKUP_DIR"
    cp "$SSHD_CONFIG" "${BACKUP_DIR}/sshd_config"
    ufw status verbose > "${BACKUP_DIR}/ufw.rules" 2>/dev/null || true
    cp /etc/fail2ban/jail.local "${BACKUP_DIR}/jail.local" 2>/dev/null || true
    cp /etc/sysctl.d/99-claude-proxy.conf "${BACKUP_DIR}/99-claude-proxy.conf" 2>/dev/null || true
    log_ok "Бэкап в ${BACKUP_DIR}"
else
    log_cmd "mkdir -p ${BACKUP_DIR}"
    log_cmd "cp ${SSHD_CONFIG} ${BACKUP_DIR}/sshd_config"
fi

# ------------------------------------------------------------------------------
# Шаг 2: Создание пользователя
# ------------------------------------------------------------------------------
log_section "2. Пользователь ${TARGET_USER}"

if id "$TARGET_USER" &>/dev/null; then
    log_info "Пользователь ${TARGET_USER} уже существует"
else
    run useradd -m -s /bin/bash "$TARGET_USER"
    run passwd "$TARGET_USER"
    log_ok "Пользователь ${TARGET_USER} создан"
fi

# Добавление в sudo (проверка группы: sudo или wheel)
if getent group sudo >/dev/null; then
    SUDO_GROUP="sudo"
elif getent group wheel >/dev/null; then
    SUDO_GROUP="wheel"
else
    log_fail "Группа sudo/wheel не найдена"
    exit 2
fi

if id -nG "$TARGET_USER" | grep -qw "$SUDO_GROUP"; then
    log_info "${TARGET_USER} уже в группе ${SUDO_GROUP}"
else
    run usermod -aG "$SUDO_GROUP" "$TARGET_USER"
    log_ok "${TARGET_USER} добавлен в ${SUDO_GROUP}"
fi

# ------------------------------------------------------------------------------
# Шаг 3: Копирование SSH-ключей
# ------------------------------------------------------------------------------
log_section "3. SSH-ключи для ${TARGET_USER}"

USER_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
USER_SSH_DIR="${USER_HOME}/.ssh"
USER_AUTH_KEYS="${USER_SSH_DIR}/authorized_keys"

if [[ "$DRY_RUN" != "true" ]]; then
    mkdir -p "$USER_SSH_DIR"
    chmod 700 "$USER_SSH_DIR"

    if [[ -f "$USER_AUTH_KEYS" && -s "$USER_AUTH_KEYS" ]]; then
        log_info "authorized_keys уже существует — дополняю"
        # Добавляем только те ключи, которых нет
        while IFS= read -r key; do
            [[ -z "$key" ]] && continue
            [[ "$key" =~ ^# ]] && continue
            if ! grep -qF "$key" "$USER_AUTH_KEYS" 2>/dev/null; then
                echo "$key" >> "$USER_AUTH_KEYS"
            fi
        done < "$ROOT_AUTH_KEYS"
    else
        cp "$ROOT_AUTH_KEYS" "$USER_AUTH_KEYS"
    fi

    chmod 600 "$USER_AUTH_KEYS"
    chown -R "${TARGET_USER}:${TARGET_USER}" "$USER_SSH_DIR"
    log_ok "Ключи скопированы в ${USER_AUTH_KEYS}"
else
    log_cmd "cp ${ROOT_AUTH_KEYS} ${USER_AUTH_KEYS}"
    log_cmd "chmod 600 ${USER_AUTH_KEYS}"
    log_cmd "chown -R ${TARGET_USER}:${TARGET_USER} ${USER_SSH_DIR}"
fi

# ------------------------------------------------------------------------------
# Шаг 4: Харденинг sshd_config
# ------------------------------------------------------------------------------
log_section "4. Харденинг ${SSHD_CONFIG}"

# Формируем новый конфиг: удаляем старые параметры, добавляем наши
HARDENING_PARAMS=(
    "Port ${SSH_PORT}"
    "PermitRootLogin no"
    "PasswordAuthentication no"
    "PubkeyAuthentication yes"
    "PermitEmptyPasswords no"
    "ChallengeResponseAuthentication no"
    "UsePAM yes"
    "ClientAliveInterval 60"
    "ClientAliveCountMax 720"
    "MaxAuthTries 3"
    "MaxSessions 5"
    "LoginGraceTime 30"
    "Protocol 2"
    "X11Forwarding no"
    "AllowAgentForwarding no"
    "AllowTcpForwarding yes"      # нужно для SSH-туннеля к панели 3x-ui
    "PermitTunnel no"
)

# Создаём копию без старых параметров
NEW_CONFIG_TMP=$(mktemp)
if [[ "$DRY_RUN" != "true" ]]; then
    # Удаляем строки, начинающиеся с параметров, которые мы переопределяем
    grep -vE '^\s*(Port|PermitRootLogin|PasswordAuthentication|PubkeyAuthentication|PermitEmptyPasswords|ChallengeResponseAuthentication|UsePAM|ClientAliveInterval|ClientAliveCountMax|MaxAuthTries|MaxSessions|LoginGraceTime|Protocol|X11Forwarding|AllowAgentForwarding|AllowTcpForwarding|PermitTunnel)\s' \
        "$SSHD_CONFIG" > "$NEW_CONFIG_TMP"

    # Добавляем наш блок
    {
        echo ""
        echo "# ===== Claude AI VPS hardening — $(date) ====="
        for p in "${HARDENING_PARAMS[@]}"; do
            echo "$p"
        done
        echo "# ===== end ====="
    } >> "$NEW_CONFIG_TMP"

    # Проверка синтаксиса ДО замены
    if ! sshd -t -f "$NEW_CONFIG_TMP"; then
        log_fail "Синтаксис нового конфига невалиден. Откат."
        rm -f "$NEW_CONFIG_TMP"
        exit 2
    fi
    log_ok "Синтаксис нового конфига валиден"

    # Применяем
    cp "$NEW_CONFIG_TMP" "$SSHD_CONFIG"
    rm -f "$NEW_CONFIG_TMP"
    log_ok "Конфиг применён"
else
    for p in "${HARDENING_PARAMS[@]}"; do
        log_cmd "echo \"$p\" >> ${SSHD_CONFIG}"
    done
fi

# ------------------------------------------------------------------------------
# Шаг 5: Проверка и перезапуск SSH
# ------------------------------------------------------------------------------
log_section "5. Перезапуск SSH"

if [[ "$DRY_RUN" != "true" ]]; then
    if ! sshd -t; then
        log_fail "sshd -t провален. Восстанавливаю из бэкапа."
        cp "${BACKUP_DIR}/sshd_config" "$SSHD_CONFIG"
        systemctl restart ssh
        exit 2
    fi

    # Открываем новый порт в firewall ДО перезапуска (если ufw уже активен)
    if systemctl is-active --quiet ufw 2>/dev/null; then
        ufw allow "${SSH_PORT}/tcp" comment 'SSH (new port)' >/dev/null 2>&1 || true
    fi

    systemctl restart ssh
    sleep 2

    if systemctl is-active --quiet ssh; then
        log_ok "SSH перезапущен на порту ${SSH_PORT}"
    else
        log_fail "SSH не запустился. Проверьте консоль провайдера."
        exit 2
    fi
else
    log_cmd "sshd -t"
    log_cmd "systemctl restart ssh"
fi

# ------------------------------------------------------------------------------
# Шаг 6: fail2ban
# ------------------------------------------------------------------------------
if [[ "$SKIP_FAIL2BAN" != "true" ]]; then
    log_section "6. fail2ban"

    if ! dpkg -l | grep -q fail2ban; then
        run apt-get install -y fail2ban
    fi

    JAIL_LOCAL="/etc/fail2ban/jail.local"

    read -r -d '' JAIL_CONTENT <<EOF
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 3
banaction = ufw

[sshd]
enabled = true
port    = ${SSH_PORT}
logpath = %(sshd_log)s
backend = systemd
EOF

    if [[ "$DRY_RUN" != "true" ]]; then
        echo "$JAIL_CONTENT" > "$JAIL_LOCAL"
        log_ok "Записан ${JAIL_LOCAL}"
        systemctl enable fail2ban
        systemctl restart fail2ban
        sleep 2
        if systemctl is-active --quiet fail2ban; then
            log_ok "fail2ban запущен"
        else
            log_warn "fail2ban не запустился — проверьте journalctl -u fail2ban"
        fi
    else
        log_cmd "echo \"...\" > ${JAIL_LOCAL}"
        log_cmd "systemctl restart fail2ban"
    fi
else
    log_info "fail2ban пропущен (--skip-fail2ban)"
fi

# ------------------------------------------------------------------------------
# Шаг 7: ufw
# ------------------------------------------------------------------------------
if [[ "$SKIP_FIREWALL" != "true" ]]; then
    log_section "7. ufw (firewall)"

    if ! command -v ufw >/dev/null; then
        run apt-get install -y ufw
    fi

    if [[ "$DRY_RUN" != "true" ]]; then
        ufw --force default deny incoming
        ufw --force default allow outgoing
        ufw allow "${SSH_PORT}/tcp" comment 'SSH'
        ufw --force enable
        log_ok "ufw активирован"
        echo
        ufw status verbose
    else
        log_cmd "ufw default deny incoming"
        log_cmd "ufw allow ${SSH_PORT}/tcp"
        log_cmd "ufw --force enable"
    fi
else
    log_info "ufw пропущен (--skip-firewall)"
fi

# ------------------------------------------------------------------------------
# Шаг 8: Автообновления
# ------------------------------------------------------------------------------
log_section "8. Автообновления безопасности"

if ! dpkg -l | grep -q unattended-upgrades; then
    run apt-get install -y unattended-upgrades
fi

AUTO_UPGRADES="/etc/apt/apt.conf.d/20auto-upgrades"
write_file "$AUTO_UPGRADES" 'APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";'

# ------------------------------------------------------------------------------
# Шаг 9: sysctl
# ------------------------------------------------------------------------------
if [[ "$SKIP_SYSCTL" != "true" ]]; then
    log_section "9. sysctl (BBR + TCP tuning)"

    SYSCTL_FILE="/etc/sysctl.d/99-claude-proxy.conf"

    read -r -d '' SYSCTL_CONTENT <<'EOF'
# Сетевая производительность
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1

# Буферы
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# Защита
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.tcp_syncookies = 1
EOF

    write_file "$SYSCTL_FILE" "$SYSCTL_CONTENT"

    if [[ "$DRY_RUN" != "true" ]]; then
        sysctl -p "$SYSCTL_FILE"
        log_ok "sysctl применён"
    else
        log_cmd "sysctl -p ${SYSCTL_FILE}"
    fi
else
    log_info "sysctl пропущен (--skip-sysctl)"
fi

# ------------------------------------------------------------------------------
# Шаг 10: Часовой пояс (информативно)
# ------------------------------------------------------------------------------
log_section "10. Часовой пояс (проверка)"

CURRENT_TZ=$(timedatectl show -p Timezone --value 2>/dev/null || echo "unknown")
if [[ "$CURRENT_TZ" == "Etc/UTC" || "$CURRENT_TZ" == "UTC" ]]; then
    log_warn "Часовой пояс UTC — рекомендуется установить по локации VPS"
    log_info "Пример: timedatectl set-timezone Europe/Berlin"
    log_info "         timedatectl set-timezone America/New_York"
else
    log_ok "Часовой пояс: ${CURRENT_TZ}"
fi

# ------------------------------------------------------------------------------
# Итог
# ------------------------------------------------------------------------------
log_section "📊 Итог"

echo "  Шагов выполнено: ${STEPS_DONE}"
echo "  Предупреждений:  ${WARNINGS}"
echo "  Ошибок:          ${FAILURES}"
echo "  Бэкап:           ${BACKUP_DIR}"
echo

if [[ "$DRY_RUN" != "true" ]]; then
    echo -e "${GREEN}${BOLD}✅ Харденинг завершён.${NC}"
    echo
    echo -e "${YELLOW}${BOLD}⚠️  ВАЖНО — ПРОВЕРЬТЕ ДОСТУП ПРЯМО СЕЙЧАС:${NC}"
    echo -e "   1. Откройте НОВЫЙ терминал на ПК"
    echo -e "   2. Выполните:"
    echo -e "      ${BOLD}ssh -p ${SSH_PORT} ${TARGET_USER}@<IP_VPS>${NC}"
    echo -e "   3. Убедитесь, что вход работает"
    echo -e "   4. Только после этого закройте текущую сессию"
    echo
    echo -e "${YELLOW}   Если вход не работает — используйте веб-консоль провайдера:${NC}"
    echo -e "      ${BOLD}sudo ./${SCRIPT_NAME} --rollback${NC}"
    echo
else
    echo -e "${YELLOW}${BOLD}ℹ️  Dry-run: изменения не применены.${NC}"
fi

exit 0
