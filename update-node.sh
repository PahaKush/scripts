#!/bin/bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1" >&2; }
log_err()  { echo -e "${RED}[ERROR]${NC} $1" >&2; }

AGENT_TOKEN=${1:-}
PORTS_ARGS=${2:-}

if [ -z "$AGENT_TOKEN" ] || [ -z "$PORTS_ARGS" ]; then
    log_err "Бот не передал токен или настройки портов. Убедитесь, что скопировали команду полностью."
    exit 1
fi

if [ "$EUID" -ne 0 ]; then
    log_err "Пожалуйста, запустите скрипт от имени root (sudo)."
    exit 1
fi

if ! command -v docker &> /dev/null; then
    log_err "Docker не установлен на этом сервере. Обновление невозможно."
    exit 1
fi

AGENT_IMAGE="ghcr.io/pahakush/private-net-node-agent:2.0.0"

log_info "Скачивание свежего образа агента ($AGENT_IMAGE)..."
docker pull $AGENT_IMAGE

log_info "Остановка и удаление старого контейнера..."
docker rm -f vpn-node >/dev/null 2>&1 || true

log_info "Запуск обновленного агента (Stateless mode)..."

docker run -d --name vpn-node --restart=always \
    --cap-add=NET_ADMIN --sysctl net.ipv4.ip_forward=1 \
    --device /dev/net/tun:/dev/net/tun \
    -v /lib/modules:/lib/modules:ro \
    --ulimit nofile=65536:65536 \
    $PORTS_ARGS \
    -e AGENT_TOKEN="$AGENT_TOKEN" \
    $AGENT_IMAGE

log_info "Ожидание запуска агента и генерации новых ключей..."
FINGERPRINT=""

for i in {1..15}; do
    FINGERPRINT=$(docker logs vpn-node 2>&1 | grep -oE "[A-Fa-f0-9]{64}" | tr '[:upper:]' '[:lower:]' | head -n 1 || true)
    if [ -n "$FINGERPRINT" ]; then
        break
    fi
    sleep 1
done

if [ -z "$FINGERPRINT" ]; then
    log_err "Не удалось получить новый отпечаток. Выполните 'docker logs vpn-node' вручную."
    exit 1
fi

echo -e "\n${GREEN}==========================================================${NC}"
echo -e "Агент успешно обновлен и запущен!"
echo -e ""
echo -e "${RED}ВАЖНО: При пересоздании изменился сертификат безопасности.${NC}"
echo -e "Скопируйте новый отпечаток ниже и отправьте его боту:\n"
echo -e "  ${YELLOW}$FINGERPRINT${NC}  \n"
echo -e "В меню сервера нажмите: ${GREEN}Сменить TLS Отпечаток${NC}"
echo -e "После этого нажмите:    ${GREEN}Скрипт выполнен, восстановить доступы!${NC}"
echo -e "${GREEN}==========================================================${NC}\n"