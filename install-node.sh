#!/bin/bash
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info() { echo -e "${GREEN}[INFO]${NC} $1" >&2; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
log_err()  { echo -e "${RED}[ERROR]${NC} $1" >&2; }

AGENT_TOKEN=${1:-}
AGENT_TAG=${AGENT_TAG:-2.4.1}
# Домен для КЛИЕНТСКИХ конфигов. Не путать с адресом, по которому бот ходит в API агента:
# бот всегда ходит по IP (не зависит от DNS), а в конфиги клиентов попадает то, что здесь.
# Указывать домен стоит заранее: адрес зашивается в уже выданные конфиги, и переехать на
# другой сервер потом можно только сохранив его — иначе все выданные конфиги умрут.
NODE_DOMAIN=${2:-${NODE_DOMAIN:-}}
NODE_DOMAIN=${NODE_DOMAIN#NODE_DOMAIN=}
AGENT_IMAGE="ghcr.io/pahakush/private-net-node-agent:${AGENT_TAG}"
TLS_VOLUME="vpn-node-tls"

if [ -z "$AGENT_TOKEN" ]; then
    log_err "Не передан AGENT_TOKEN."
    exit 1
fi
if [ "$(id -u)" -ne 0 ]; then
    log_err "Пожалуйста, запустите скрипт от имени root (sudo)."
    exit 1
fi

if ! command -v docker &> /dev/null; then
    log_warn "Docker не найден. Начинаю автоматическую установку..."
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker
    log_info "Docker успешно установлен."
fi

# Убираем старый контейнер ДО проверки портов — иначе он сам себя объявит конфликтом.
if docker ps -a --format '{{.Names}}' | grep -qx vpn-node; then
    log_warn "Найден существующий контейнер vpn-node — удаляю перед переустановкой."
    docker rm -f vpn-node >/dev/null 2>&1 || true
fi

ASSIGNED_PORTS=" "

port_busy() {
    command -v ss >/dev/null 2>&1 || return 1
    ss -lntuH 2>/dev/null | awk '{print $5}' | grep -qE "[:.]${1}\$"
}

check_and_ask_port() {
    local port_name=$1 current_port=$2 out_var=$3
    while true; do
        if port_busy "$current_port" || [[ "$ASSIGNED_PORTS" == *" $current_port "* ]]; then
            log_warn "Порт $current_port для сервиса '$port_name' занят."
            current_port=$((current_port + 1))
            # Неинтерактивный запуск (curl | bash без TTY) не должен падать: просто
            # берём следующий свободный порт и сообщаем об этом.
            if [ -t 0 ] || [ -e /dev/tty ]; then
                read -r -p "$(echo -e "${YELLOW}Введите свободный порт [по умолчанию $current_port]: ${NC}")" user_port </dev/tty || user_port=""
                current_port=${user_port:-$current_port}
            else
                log_warn "Нет TTY — автоматически выбираю $current_port."
            fi
        else
            ASSIGNED_PORTS+="$current_port "
            printf -v "$out_var" "%s" "$current_port"
            return
        fi
    done
}

log_info "Проверка доступности портов..."
check_and_ask_port "API Агента" 9090 API_PORT
check_and_ask_port "WireGuard"  51820 WG_PORT
check_and_ask_port "AmneziaWG"  51821 AWG_PORT
check_and_ask_port "SOCKS5"     1080  SOCKS_PORT
check_and_ask_port "MTProxy"    443   MTPROXY_PORT
log_info "Порты: API=$API_PORT, WG=$WG_PORT, AWG=$AWG_PORT, SOCKS=$SOCKS_PORT, MT=$MTPROXY_PORT"

log_info "Определяем публичный IPv4 сервера..."
HOST=$(curl -4 -s --max-time 5 ifconfig.me || curl -4 -s --max-time 5 api.ipify.org || curl -4 -s --max-time 5 ident.me || echo "")
if [ -z "$HOST" ]; then
    log_err "Не удалось определить публичный IPv4."
    exit 1
fi
log_info "Публичный IP: $HOST"

if [ -n "$NODE_DOMAIN" ]; then
    if ! echo "$NODE_DOMAIN" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+$'; then
        log_err "'$NODE_DOMAIN' не похож на домен. Домен идёт вторым аргументом:"
        log_err "  bash -s -- <токен> vpn.example.com"
        exit 1
    fi
    # Формально IPv4 подходит под шаблон имени хоста, но смысла в нём здесь нет: адрес
    # зашивается в конфиги, и ровно IP делает переезд на другой сервер невозможным.
    if echo "$NODE_DOMAIN" | grep -qE '^[0-9]+(\.[0-9]+){3}$'; then
        log_err "'$NODE_DOMAIN' — это IP-адрес. Домен нужен именно для того, чтобы"
        log_err "адрес в клиентских конфигах пережил переезд на другой сервер."
        exit 1
    fi
    # Резолв — предупреждение, а не ошибка: DNS мог ещё не разойтись, а установку
    # из-за этого валить незачем. Но промолчать нельзя: неверный домен обнаружится
    # только когда клиенты не смогут подключиться.
    RESOLVED=$(getent ahostsv4 "$NODE_DOMAIN" 2>/dev/null | awk '{print $1; exit}' || echo "")
    if [ -z "$RESOLVED" ]; then
        log_warn "Домен $NODE_DOMAIN сейчас не резолвится. Проверьте A-запись."
    elif [ "$RESOLVED" != "$HOST" ]; then
        log_warn "Домен $NODE_DOMAIN указывает на $RESOLVED, а публичный IP этого сервера $HOST."
    else
        log_info "Домен $NODE_DOMAIN указывает на этот сервер."
    fi
    log_info "Клиентские конфиги будут выданы с адресом: $NODE_DOMAIN"
fi

log_info "Скачивание образа агента ($AGENT_IMAGE)..."
docker pull "$AGENT_IMAGE"

docker volume create "$TLS_VOLUME" >/dev/null

log_info "Запуск Docker-контейнера..."
# --restart=always обязателен: /api/v1/system/restart завершает процесс с кодом 0,
# и при on-failure контейнер после этого не поднимется.
docker run -d --name vpn-node --restart=always \
    --cap-add=NET_ADMIN --sysctl net.ipv4.ip_forward=1 \
    --device /dev/net/tun:/dev/net/tun \
    -v /lib/modules:/lib/modules:ro \
    -v "$TLS_VOLUME":/etc/agent-tls \
    --ulimit nofile=65536:65536 \
    --log-opt max-size=10m --log-opt max-file=3 \
    -p "$API_PORT":9090 \
    -p "$WG_PORT":51820/udp \
    -p "$AWG_PORT":51821/udp \
    -p "$SOCKS_PORT":1080/tcp \
    -p "$MTPROXY_PORT":443/tcp \
    -e AGENT_TOKEN="$AGENT_TOKEN" \
    "$AGENT_IMAGE"

log_info "Ожидание генерации TLS сертификата..."
FINGERPRINT=""
for _ in $(seq 1 20); do
    FINGERPRINT=$(docker logs vpn-node 2>&1 | grep -oE "FINGERPRINT=[A-Fa-f0-9]{64}" | tail -n1 | cut -d= -f2 | tr '[:upper:]' '[:lower:]' || true)
    [ -n "$FINGERPRINT" ] && break
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
CONN="wg-node://$HOST|$API_PORT|$WG_PORT|$AWG_PORT|$SOCKS_PORT|$MTPROXY_PORT|$FINGERPRINT"
# Домен идёт ВОСЬМЫМ полем и только если задан: старые строки из 7 полей бот по-прежнему
# принимает и, как раньше, берёт адрес клиентских конфигов равным IP.
[ -n "$NODE_DOMAIN" ] && CONN="$CONN|$NODE_DOMAIN"
echo -e "${YELLOW}${CONN}${NC}"
if [ -z "$NODE_DOMAIN" ]; then
    echo -e "\n${YELLOW}Узел добавляется по IP.${NC} Адрес зашивается в выданные конфиги, поэтому"
    echo -e "перенести его на другой сервер без перевыпуска конфигов будет нельзя."
    echo -e "Если планируете переезд — переустановите, дописав домен вторым аргументом:"
    echo -e "  ${YELLOW}... | \${SUDO}bash -s -- <токен> vpn.example.com${NC}"
fi
echo -e "\nСертификат сохранён в docker volume '$TLS_VOLUME' — при обновлении узла"
echo -e "отпечаток больше не меняется, менять его в боте повторно не придётся."
echo -e "${GREEN}==========================================================${NC}\n"
