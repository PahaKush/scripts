#!/bin/bash

# ==============================================================================
# PVE-VM-Monitor: Скрипт для мониторинга дисков на ВМ через QEMU-Agent
# Версия: 1.2 (с установщиком и управлением cron)
#
# Описание: Собирает информацию о дисковом пространстве с указанных ВМ
# и отправляет ее в виде JSON на API-сервер мониторинга.
# ==============================================================================

# ==============================================================================
#                      АВТОМАТИЧЕСКИЙ УСТАНОВЩИК
# ==============================================================================
# Этот блок выполняется, только если скрипт запущен через curl/wget | bash
if [[ "$0" == "bash" || "$0" == "sh" || "$0" == *"bash" ]]; then

    # --- Настройки установщика ---
    INSTALL_DIR="/opt/scripts"
    INSTALL_PATH="$INSTALL_DIR/pve-vm-monitor.sh"
    SCRIPT_URL="https://raw.githubusercontent.com/PahaKush/scripts/main/pve-vm-monitor.sh"

    # --- Цвета (локальные для установщика) ---
    C_RESET='\033[0m'
    C_RED='\033[0;31m'
    C_GREEN='\033[0;32m'
    C_YELLOW='\033[0;33m'
    C_WHITE='\033[1;37m'
    
    echo -e "${C_WHITE}Запуск установщика PVE-VM-Monitor в автоматическом режиме...${C_RESET}"

    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${C_RED}Ошибка: Для установки скрипта в $INSTALL_DIR нужны права root.${C_RESET}"
        exit 1
    fi
    
    echo -e "Проверка/создание директории ${C_WHITE}$INSTALL_DIR${C_RESET}..."
    mkdir -p "$INSTALL_DIR"
    
    echo -e "Скачивание последней версии в ${C_WHITE}$INSTALL_PATH${C_RESET}..."
    if ! curl -fsSL "$SCRIPT_URL" -o "$INSTALL_PATH"; then
        echo -e "${C_RED}Ошибка при скачивании скрипта.${C_RESET}"
        echo -e "${C_YELLOW}Убедитесь, что URL ${C_WHITE}$SCRIPT_URL${C_RESET}${C_YELLOW} корректен.${C_RESET}"
        echo -e "${C_YELLOW}Если вы запускаете скрипт локально, используйте 'bash pve-vm-monitor.sh --help' для инструкций.${C_RESET}"
        exit 1
    fi
    
    chmod +x "$INSTALL_PATH"

    echo -e "\n${C_GREEN}Установка/обновление успешно завершено!${C_RESET}"
    echo "Скрипт сохранен и готов к использованию."
    echo
    echo "Дальнейшие шаги:"
    echo "1. (Обязательно) Отредактируйте файл конфигурации:"
    echo -e "   ${C_WHITE}nano $INSTALL_PATH${C_RESET}"
    echo -e "   ${C_YELLOW}   и укажите ваши VM_IDS и API_URL в секции НАСТРОЙКИ.${C_RESET}"
    echo
    echo "2. Для автоматического запуска по расписанию выполните:"
    echo -e "   ${C_WHITE}$INSTALL_PATH --install-cron${C_RESET}"
    echo
    echo "3. Для разового запуска мониторинга вручную:"
    echo -e "   ${C_WHITE}$INSTALL_PATH --run-once${C_RESET}"
    
    exit 0
fi

# ==============================================================================
#                      ОСНОВНОЙ КОД СКРИПТА НАЧИНАЕТСЯ ЗДЕСЬ
# ==============================================================================

# --- НАСТРОЙКИ ---
#
# Имя сервера, на котором запущен скрипт (хост Proxmox).
PVE_HOST_NAME="MyProxmoxServer-01"
# ID виртуальных машин для мониторинга (через пробел). ("100" "101" "105")
VM_IDS=("100")
# URL API-сервера для приема данных.
API_URL="https://your-monitoring-api.com/vm-agent-data"
# Файл логов для cron
LOG_FILE="/var/log/pve-vm-monitor.log"
# Расписание для cron
CRON_SCHEDULE="*/5 * * * *" # Каждые 5 минут

# Путь к самому скрипту для cron
INSTALL_PATH="/opt/scripts/$(basename "$0")"

# --- Переменная для режима отладки ---
DEBUG_MODE=0

# --- Цвета для вывода ---
C_RESET='\033[0m'; C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'; C_BLUE='\033[0;34m'; C_CYAN='\033[0;36m'; C_WHITE='\033[1;37m'; C_GRAY='\033[0;90m';

# --- Функции для вывода ---
print_header() { echo -e "\n${C_BLUE}===== $1 =====${C_RESET}"; }
print_ok() { echo -e "[${C_GREEN}  OK  ${C_RESET}] $1"; }
print_warn() { echo -e "[${C_YELLOW} WARN ${C_RESET}] $1"; }
print_error() { echo -e "[${C_RED} ERROR ${C_RESET}] $1"; }
print_info() { echo -e "[${C_CYAN} INFO ${C_RESET}] $1"; }
print_debug() {
    local message=$1; local data=$2
    if [ "$DEBUG_MODE" -eq 1 ]; then
        echo -e "${C_GRAY}    [DEBUG] $message${C_RESET}"
        if [ -n "$data" ]; then
            echo "$data" | while IFS= read -r line; do echo -e "${C_GRAY}      $line${C_RESET}"; done;
        fi
    fi
}

# --- Проверка на root ---
if [ "$(id -u)" -ne 0 ]; then
    print_error "Этот скрипт необходимо запускать от пользователя root."
    exit 1
fi

# --- Проверка зависимостей ---
check_dependencies() {
    for cmd in jq curl; do
        if ! command -v $cmd &> /dev/null; then
            print_error "Утилита '$cmd' не найдена. Установите ее: apt install $cmd"
            exit 1
        fi
    done
}

# --- Основная логика мониторинга ---
run_monitoring_task() {
    print_header "Запуск задачи мониторинга для ${#VM_IDS[@]} ВМ"
    
    for VM_ID in "${VM_IDS[@]}"; do
        echo "--------------------------------------------------"
        
        local CONFIG_JSON=$(pvesh get /nodes/"$(hostname)"/qemu/"$VM_ID"/config --output-format json 2>/dev/null)
        if [ -z "$CONFIG_JSON" ]; then
            print_error "Не удалось получить конфигурацию для VM ID $VM_ID. Пропускаем."
            continue
        fi
        
        local VM_NAME_PVE=$(echo "$CONFIG_JSON" | jq -r '.name // "unknown"')
        print_info "Обработка VM ${VM_ID} (${VM_NAME_PVE})"
        
        local VM_STATUS_JSON=$(pvesh get /nodes/"$(hostname)"/qemu/"$VM_ID"/status/current --output-format json 2>/dev/null)
        local VM_STATUS=$(echo "$VM_STATUS_JSON" | jq -r '.status // "unknown"')
        if [ "$VM_STATUS" != "running" ]; then
            print_warn "Статус: ${VM_STATUS}. Пропускаем."
            continue
        fi

        local AGENT_ENABLED=$(echo "$CONFIG_JSON" | jq -r '.agent // "0"')
        if [[ "$AGENT_ENABLED" != "1" && ! "$AGENT_ENABLED" =~ enabled=1 ]]; then
            print_warn "QEMU Guest Agent НЕ включен в конфигурации. Пропускаем."
            continue
        fi
        
        if ! qm agent "$VM_ID" ping &> /dev/null; then
            print_warn "QEMU Guest Agent не отвечает на ping. Пропускаем."
            continue
        fi

        local FS_INFO_RAW_JSON=$(qm agent "$VM_ID" get-fsinfo 2>/dev/null)
        print_debug "Сырой JSON от 'get-fsinfo':" "$FS_INFO_RAW_JSON"

        if [ -z "$FS_INFO_RAW_JSON" ]; then
            print_error "Не удалось получить информацию о дисках. Пропускаем."
            continue
        fi
        
        local MACHINE_NAME=$(qm agent "$VM_ID" get-host-name | jq -r '(.return // .["host-name"]) // ""' 2>/dev/null)
        if [ -z "$MACHINE_NAME" ]; then
            print_warn "Не удалось получить имя хоста ВМ. Будет использовано 'unknown'."
            MACHINE_NAME="unknown"
        fi
        
        local DRIVES_JSON=$(echo "$FS_INFO_RAW_JSON" | jq '
            [
                .[] |
                select(
                    .["total-bytes"] and .["total-bytes"] > 0 and
                    (.fstype | test("tmpfs|devtmpfs|squashfs") | not)
                ) |
                {
                    drive: (if .mountpoint | test(":\\\\$") then (.mountpoint | sub(":\\\\$"; "")) else .mountpoint end),
                    totalGb: (.["total-bytes"] / 1073741824 | round),
                    usedGb: (.["used-bytes"] / 1073741824 | round),
                    freeGb: ((.["total-bytes"] - .["used-bytes"]) / 1073741824 | round)
                }
            ]
        ')
        
        local PAYLOAD
        PAYLOAD=$(jq -n \
                      --arg pve_host "$PVE_HOST_NAME" \
                      --arg vm_name "$VM_NAME_PVE" \
                      --arg guest_hostname "$MACHINE_NAME" \
                      --argjson drives "$DRIVES_JSON" \
                      '{
                          pveHost: $pve_host,
                          vmName: $vm_name,
                          guestHostname: $guest_hostname,
                          timestamp: (now | todateiso8601), 
                          drives: $drives
                       }')
        print_debug "Итоговый JSON payload для отправки:" "$PAYLOAD"

        print_info "Подготовлены данные для отправки."

        # Отправляем данные
        local RESPONSE_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
             --connect-timeout 10 \
             -m 15 \
             -H "Content-Type: application/json" \
             -d "$PAYLOAD" \
             "$API_URL")

        if [ "$RESPONSE_CODE" -ge 200 ] && [ "$RESPONSE_CODE" -lt 300 ]; then
            print_ok "Данные успешно отправлены на API (HTTP статус: $RESPONSE_CODE)."
        else
            print_error "Ошибка отправки данных на API (HTTP статус: $RESPONSE_CODE)."
        fi
    done
    echo "--------------------------------------------------"
    print_header "Задача мониторинга завершена"
}

# --- Управление Cron ---
install_cron() {
    print_header "Установка задачи в Cron"
    CRON_COMMAND="$CRON_SCHEDULE $INSTALL_PATH --run-once >> $LOG_FILE 2>&1"
    
    if crontab -l 2>/dev/null | grep -q "$INSTALL_PATH"; then
        print_info "Задача для этого скрипта уже существует в cron. Обновление..."
        (crontab -l 2>/dev/null | grep -v "$INSTALL_PATH"; echo "$CRON_COMMAND") | crontab -
    else
        print_info "Добавление новой задачи в cron..."
        (crontab -l 2>/dev/null; echo "$CRON_COMMAND") | crontab -
    fi
    
    if [ $? -eq 0 ]; then
        print_ok "Задача успешно добавлена/обновлена в cron."
        print_info "Расписание: ${C_WHITE}каждые 5 минут${C_RESET}."
        print_info "Логи будут записываться в: ${C_WHITE}$LOG_FILE${C_RESET}."
    else
        print_error "Не удалось добавить задачу в cron."
    fi
}

uninstall_cron() {
    print_header "Удаление задачи из Cron"
    if crontab -l 2>/dev/null | grep -q "$INSTALL_PATH"; then
        (crontab -l 2>/dev/null | grep -v "$INSTALL_PATH") | crontab -
        if [ $? -eq 0 ]; then
            print_ok "Задача для скрипта успешно удалена из cron."
        else
            print_error "Не удалось удалить задачу из cron."
        fi
    else
        print_warn "Задача для этого скрипта не найдена в cron."
    fi
}

# --- Справка ---
print_help() {
    echo "PVE-VM-Monitor: Скрипт для мониторинга дисков на ВМ."
    echo
    echo -e "Использование: ${C_WHITE}$(basename "$0") [ОПЦИЯ]${C_RESET}"
    echo
    echo "Опции:"
    echo -e "  ${C_CYAN}--run-once${C_RESET}        Запустить задачу мониторинга один раз и вывести результат в консоль."
    echo -e "  ${C_CYAN}--debug${C_RESET}           Включить режим отладки. Используется совместно с --run-once."
    echo -e "                       Пример: $(basename "$0") --run-once --debug"
    echo
    echo -e "  ${C_CYAN}--install-cron${C_RESET}    Добавить или обновить задачу для автоматического запуска в cron."
    echo -e "  ${C_CYAN}--uninstall-cron${C_RESET}  Удалить задачу из cron."
    echo -e "  ${C_CYAN}-h, --help${C_RESET}         Показать это справочное сообщение."
    echo
    echo "По умолчанию (без опций) будет показана эта справка."
}

# ==============================================================================
#                                ГЛАВНАЯ ФУНКЦИЯ
# ==============================================================================
main() {
    check_dependencies
    
    # Парсинг аргументов для одновременной обработки флагов
    RUN_FLAG=0
    while [[ $# -gt 0 ]]; do
        key="$1"
        case $key in
            --run-once)
            RUN_FLAG=1
            shift
            ;;
            --debug)
            DEBUG_MODE=1
            shift
            ;;
            --install-cron)
            install_cron
            exit 0
            ;;
            --uninstall-cron)
            uninstall_cron
            exit 0
            ;;
            -h|--help)
            print_help
            exit 0
            ;;
            *)
            print_error "Неизвестная опция: $1"
            print_help
            exit 1
            ;;
        esac
    done

    # Выполняем основную задачу, если был флаг --run-once
    if [ "$RUN_FLAG" -eq 1 ]; then
        run_monitoring_task
    else
        # Если не было флагов действия, показываем справку
        print_warn "Не указана опция для выполнения."
        print_help
    fi
}

main "$@"