#!/bin/bash

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1" >&2; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
log_err()  { echo -e "${RED}[ERROR]${NC} $1" >&2; }

AGENT_TOKEN=${1:-}

if [ -z "$AGENT_TOKEN" ]; then
    log_err "Не передан AGENT_TOKEN."
    exit 1
fi

if [ "$EUID" -ne 0 ]; then
    log_err "Пожалуйста, запустите скрипт от имени root (sudo)."
    exit 1
fi

# Проверка и автоматическая установка Docker
if ! command -v docker &> /dev/null; then
    log_warn "Docker не найден. Начинаю автоматическую установку..."
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker
    log_info "Docker успешно установлен."
fi

check_and_ask_port() {
    local port_name=$1
    local current_port=$2

    while true; do
        if command -v ss &> /dev/null && ss -lntu | awk '{print $5}' | grep -E ":${current_port}$" >/dev/null 2>&1; then
            log_warn "Порт $current_port для сервиса '$port_name' уже занят!"
            local next_port=$((current_port + 1))
            
            # Читаем ввод напрямую из TTY, так как скрипт запущен через curl | bash
            read -p "$(echo -e ${YELLOW}Введите свободный порт [по умолчанию $next_port]: ${NC})" user_port </dev/tty
            
            current_port=${user_port:-$next_port}
        else
            echo "$current_port"
            return
        fi
    done
}

# Проверка занятых портов
log_info "Проверка доступности портов..."

API_PORT=$(check_and_ask_port "API Агента" 9090)
WG_PORT=$(check_and_ask_port "WireGuard" 51820)
AWG_PORT=$(check_and_ask_port "AmneziaWG" 51821)
SOCKS_PORT=$(check_and_ask_port "SOCKS5" 1080)
MTPROXY_PORT=$(check_and_ask_port "MTProxy" 443)

log_info "Выбранные порты: API=$API_PORT, WG=$WG_PORT, AWG=$AWG_PORT, SOCKS=$SOCKS_PORT, MT=$MTPROXY_PORT"

# Определение публичного IPv4
log_info "Определяем публичный IPv4 сервера..."
HOST=$(curl -4 -s --max-time 5 ifconfig.me || curl -4 -s --max-time 5 api.ipify.org || curl -4 -s --max-time 5 ident.me || echo "")

if [ -z "$HOST" ]; then
    log_err "Не удалось определить публичный IPv4. Убедитесь, что сервер имеет IPv4-адрес и доступ к интернету."
    exit 1
fi
log_info "Публичный IP: $HOST"

AGENT_IMAGE="ghcr.io/pahakush/private-net-node-agent:2.0.0"

log_info "Скачивание образа агента..."
docker pull $AGENT_IMAGE

docker rm -f vpn-node >/dev/null 2>&1 || true

log_info "Запуск Docker-контейнера (Stateless mode)..."
docker run -d --name vpn-node --restart=always \
    --cap-add=NET_ADMIN --sysctl net.ipv4.ip_forward=1 \
    --device /dev/net/tun:/dev/net/tun \
    -v /lib/modules:/lib/modules:ro \
    --ulimit nofile=65536:65536 \
    -p $API_PORT:9090 \
    -p $WG_PORT:51820/udp \
    -p $AWG_PORT:51821/udp \
    -p $SOCKS_PORT:1080/tcp \
    -p $MTPROXY_PORT:443/tcp \
    -e AGENT_TOKEN="$AGENT_TOKEN" \
    $AGENT_IMAGE

log_info "Ожидание генерации TLS сертификатов..."
FINGERPRINT=""

# Ожидание до 15 секунд
for i in {1..15}; do
    FINGERPRINT=$(docker logs vpn-node 2>&1 | grep -oE "[A-Fa-f0-9]{64}" | tr '[:upper:]' '[:lower:]' | head -n 1 || true)
    if [ -n "$FINGERPRINT" ]; then
        break
    fi
    sleep 1
done

if [ -z "$FINGERPRINT" ]; then
    log_err "Не удалось найти TLS Fingerprint в логах контейнера. Вывод логов:"
    docker logs vpn-node
    exit 1
fi

echo -e "\n${GREEN}==========================================================${NC}"
echo -e "✅ Установка успешно завершена!"
echo -e "Скопируйте строку ниже и отправьте её боту:\n"
echo -e "${YELLOW}wg-node://$HOST|$API_PORT|$WG_PORT|$AWG_PORT|$SOCKS_PORT|$MTPROXY_PORT|$FINGERPRINT${NC}"
echo -e "${GREEN}==========================================================${NC}\n"