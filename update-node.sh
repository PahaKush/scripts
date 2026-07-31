#!/bin/bash
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info() { echo -e "${GREEN}[INFO]${NC} $1" >&2; }
log_err()  { echo -e "${RED}[ERROR]${NC} $1" >&2; }

AGENT_TOKEN=${1:-}
PORTS_ARGS=${2:-}
AGENT_TAG=${AGENT_TAG:-2.4.1}
AGENT_IMAGE="ghcr.io/pahakush/private-net-node-agent:${AGENT_TAG}"
TLS_VOLUME="vpn-node-tls"

if [ -z "$AGENT_TOKEN" ] || [ -z "$PORTS_ARGS" ]; then
    log_err "Бот не передал токен или настройки портов. Скопируйте команду полностью."
    exit 1
fi
if [ "$(id -u)" -ne 0 ]; then
    log_err "Пожалуйста, запустите скрипт от имени root (sudo)."
    exit 1
fi
if ! command -v docker &> /dev/null; then
    log_err "Docker не установлен на этом сервере. Обновление невозможно."
    exit 1
fi

# Был ли у узла персистентный сертификат до этого обновления?
HAD_VOLUME=$(docker volume ls --format '{{.Name}}' | grep -qx "$TLS_VOLUME" && echo yes || echo no)

log_info "Скачивание свежего образа агента ($AGENT_IMAGE)..."
docker pull "$AGENT_IMAGE"

log_info "Остановка и удаление старого контейнера..."
docker rm -f vpn-node >/dev/null 2>&1 || true

docker volume create "$TLS_VOLUME" >/dev/null

log_info "Запуск обновлённого агента..."
# shellcheck disable=SC2086  # PORTS_ARGS приходит от бота как готовая строка -p ...
docker run -d --name vpn-node --restart=always \
    --cap-add=NET_ADMIN --sysctl net.ipv4.ip_forward=1 \
    --device /dev/net/tun:/dev/net/tun \
    -v /lib/modules:/lib/modules:ro \
    -v "$TLS_VOLUME":/etc/agent-tls \
    --ulimit nofile=65536:65536 \
    --log-opt max-size=10m --log-opt max-file=3 \
    $PORTS_ARGS \
    -e AGENT_TOKEN="$AGENT_TOKEN" \
    "$AGENT_IMAGE"

log_info "Ожидание запуска агента..."
FINGERPRINT=""
for _ in $(seq 1 20); do
    FINGERPRINT=$(docker logs vpn-node 2>&1 | grep -oE "FINGERPRINT=[A-Fa-f0-9]{64}" | tail -n1 | cut -d= -f2 | tr '[:upper:]' '[:lower:]' || true)
    [ -n "$FINGERPRINT" ] && break
    sleep 1
done

if [ -z "$FINGERPRINT" ]; then
    log_err "Не удалось получить отпечаток. Выполните 'docker logs vpn-node' вручную."
    exit 1
fi

REUSED=$(docker logs vpn-node 2>&1 | grep -c "Loaded existing TLS certificate" || true)

echo -e "\n${GREEN}==========================================================${NC}"
echo -e "✅ Агент обновлён и запущен (версия ${AGENT_TAG})."
echo -e ""
if [ "$REUSED" -gt 0 ]; then
    echo -e "${GREEN}Сертификат переиспользован — отпечаток НЕ изменился.${NC}"
    echo -e "Менять его в боте не нужно. Бот сам увидит новый instance_id и"
    echo -e "восстановит доступы на всех сервисах (уведомление придёт в чат)."
else
    if [ "$HAD_VOLUME" = "no" ]; then
        echo -e "${YELLOW}Это первое обновление с персистентным сертификатом.${NC}"
        echo -e "Прежний сертификат лежал внутри контейнера и исчез вместе с ним,"
        echo -e "поэтому отпечаток сменился ОДИН раз. Дальше он будет стабилен."
    fi
    echo -e "${RED}ВАЖНО: отпечаток изменился.${NC} Отправьте боту новый:\n"
    echo -e "  ${YELLOW}$FINGERPRINT${NC}\n"
    echo -e "В меню сервера: ${GREEN}🔑 Сменить TLS-отпечаток${NC}"
fi
echo -e "${GREEN}==========================================================${NC}\n"
