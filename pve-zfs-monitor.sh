#!/bin/bash

# ==============================================================================
# PVE-ZFS-Monitor: Скрипт для мониторинга состояния ZFS пулов и дисков
# Версия: 1.3
#
# Описание: Собирает информацию о здоровье ZFS пулов, ошибках дисков
# и критичных атрибутах SMART, затем отправляет JSON на API-сервер.
# ==============================================================================

# ==============================================================================
#                      АВТОМАТИЧЕСКИЙ УСТАНОВЩИК
# ==============================================================================
# Этот блок выполняется, только если скрипт запущен через curl/wget | bash
if [[ "$0" == "bash" || "$0" == "sh" || "$0" == *"bash" ]]; then

    # --- Настройки установщика ---
    INSTALL_DIR="/opt/scripts"
    INSTALL_PATH="$INSTALL_DIR/pve-zfs-monitor.sh"
    SCRIPT_URL="https://raw.githubusercontent.com/PahaKush/scripts/main/pve-zfs-monitor.sh"

    # --- Цвета (локальные для установщика) ---
    C_RESET='\033[0m'
    C_RED='\033[0;31m'
    C_GREEN='\033[0;32m'
    C_YELLOW='\033[0;33m'
    C_WHITE='\033[1;37m'
    
    echo -e "${C_WHITE}Запуск установщика PVE-ZFS-Monitor в автоматическом режиме...${C_RESET}"

    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${C_RED}Ошибка: Для установки скрипта в $INSTALL_DIR нужны права root.${C_RESET}"
        exit 1
    fi
    
    echo -e "Проверка/создание директории ${C_WHITE}$INSTALL_DIR${C_RESET}..."
    mkdir -p "$INSTALL_DIR"
    
    echo -e "Скачивание последней версии в ${C_WHITE}$INSTALL_PATH${C_RESET}..."
    if ! curl -fsSL "$SCRIPT_URL" -o "$INSTALL_PATH"; then
        echo -e "${C_RED}Ошибка при скачивании скрипта.${C_RESET}"
        echo -e "${C_YELLOW}Если вы запускаете скрипт локально, используйте 'bash pve-zfs-monitor.sh --help' для инструкций.${C_RESET}"
        exit 1
    fi
    
    chmod +x "$INSTALL_PATH"

    echo -e "\n${C_GREEN}Установка/обновление успешно завершено!${C_RESET}"
    echo "Скрипт сохранен и готов к использованию."
    echo
    echo "Дальнейшие шаги:"
    echo "1. (Обязательно) Отредактируйте файл конфигурации:"
    echo -e "   ${C_WHITE}nano $INSTALL_PATH${C_RESET}"
    echo -e "   ${C_YELLOW}   и укажите ваш PVE_HOST_NAME и API_URL в секции НАСТРОЙКИ.${C_RESET}"
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
# URL API-сервера для приема данных.
API_URL="https://your-monitoring-api.com/zfs-health"
# Файл логов для cron
LOG_FILE="/var/log/pve-zfs-monitor.log"
# Расписание для cron
CRON_SCHEDULE="0 * * * *" # Каждый час

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
    if ! command -v jq &> /dev/null || ! command -v smartctl &> /dev/null; then
        print_error "Необходимые утилиты ('jq', 'smartmontools') не найдены."
        print_info "Пожалуйста, установите их: apt update && apt install jq smartmontools"
        exit 1
    fi
    if ! command -v zpool &> /dev/null; then
        print_info "Команда 'zpool' не найдена. На этом хосте нет ZFS."
        exit 0
    fi
}

# --- Основная логика мониторинга ---
run_monitoring_task() {
    print_header "Сбор информации о состоянии ZFS пулов"
    
    local POOLS=$(zpool list -H -o name 2>/dev/null)
    if [ -z "$POOLS" ]; then
        print_info "На сервере не найдено ZFS пулов. Завершение."
        return
    fi
    
    local ALL_POOLS_JSON='[]'
    
    for POOL_NAME in $POOLS; do
        print_info "Анализ пула: ${C_WHITE}${POOL_NAME}${C_RESET}"
        
        local POOL_STATUS_RAW=$(zpool status "$POOL_NAME")
        print_debug "POOL_STATUS_RAW:" "$POOL_STATUS_RAW"
        
        local POOL_HEALTH=$(echo "$POOL_STATUS_RAW" | grep "state:" | awk '{print $2}')
        local POOL_CAPACITY=$(zpool list -H -o capacity "$POOL_NAME" | tr -d '%')
        local POOL_FRAGMENTATION=$(zpool list -H -o frag "$POOL_NAME" | tr -d '%')
        local POOL_SCRUB_INFO=$(echo "$POOL_STATUS_RAW" | grep "scan:" | sed -e 's/^[[:space:]]*scan:[[:space:]]*//')
        
        local DEVICES_JSON='[]'
        local DISK_LINES=$(echo "$POOL_STATUS_RAW" | grep -E '^\s+(ata-|nvme-|scsi-|usb-)[^[:space:]]+')
        print_debug "Отфильтрованные строки с дисками для обработки:" "$DISK_LINES"

        if [ -n "$DISK_LINES" ]; then
            local devices_json_lines=""
            # Обрабатываем все диски и сразу собираем их в JSON-массив
            while IFS= read -r line; do
                local DISK_ID=$(echo "$line" | awk '{print $1}')
                local DISK_STATE=$(echo "$line" | awk '{print $2}')
                local READ_ERRORS=$(echo "$line" | awk '{print $3}')
                local WRITE_ERRORS=$(echo "$line" | awk '{print $4}')
                local CKSUM_ERRORS=$(echo "$line" | awk '{print $5}')
                
                print_debug "Обработка диска:" "$DISK_ID"
                
                local REALLOCATED_SECTORS="" PENDING_SECTORS="" SSD_PERCENT_USED="" SMART_STATUS="N/A"
                local PARENT_DISK_ID=${DISK_ID%-part[0-9]*}
                local DEVICE_PATH="/dev/disk/by-id/$PARENT_DISK_ID"
                
                if [ -e "$DEVICE_PATH" ]; then
                    local DEVICE_TYPE_FLAG=""
                    case "$DISK_ID" in nvme-*) DEVICE_TYPE_FLAG="-d nvme";; ata-*) DEVICE_TYPE_FLAG="-d ata";; usb-*) DEVICE_TYPE_FLAG="-d sat";; esac
                    local SMART_OUTPUT=$(smartctl -a $DEVICE_TYPE_FLAG "$DEVICE_PATH" 2>/dev/null)
                    if [ -n "$SMART_OUTPUT" ]; then
                        if echo "$SMART_OUTPUT" | grep -qi "FAILED"; then SMART_STATUS="FAILED"; else SMART_STATUS="PASSED"; fi
                        REALLOCATED_SECTORS=$(echo "$SMART_OUTPUT" | grep -m 1 -E "Reallocated_Sector_Ct|Reallocated_Event_Count" | awk '{print $10}')
                        PENDING_SECTORS=$(echo "$SMART_OUTPUT" | grep -m 1 "Current_Pending_Sector" | awk '{print $10}')
                        SSD_PERCENT_USED=$(echo "$SMART_OUTPUT" | grep -m 1 "Percentage Used:" | awk '{print $3}' | tr -d '%')
                    else
                        SMART_STATUS="UNKNOWN"
                    fi
                else
                    SMART_STATUS="NOT_FOUND"
                fi

                devices_json_lines+=$(jq -n \
                    --arg id           "$DISK_ID" \
                    --arg state        "$DISK_STATE" \
                    --arg read         "${READ_ERRORS:-0}" \
                    --arg write        "${WRITE_ERRORS:-0}" \
                    --arg cksum        "${CKSUM_ERRORS:-0}" \
                    --arg status       "$SMART_STATUS" \
                    --arg reallocated  "${REALLOCATED_SECTORS:-0}" \
                    --arg pending      "${PENDING_SECTORS:-0}" \
                    --arg ssd_used     "${SSD_PERCENT_USED:-0}" \
                    '{
                        id: $id, state: $state, smartStatus: $status,
                        readErrors: ($read | tonumber), writeErrors: ($write | tonumber),
                        checksumErrors: ($cksum | tonumber), reallocatedSectors: ($reallocated | tonumber),
                        pendingSectors: ($pending | tonumber), ssdPercentUsed: ($ssd_used | tonumber)
                    }')
                
            done <<< "$DISK_LINES"
            DEVICES_JSON=$(echo "$devices_json_lines" | jq -s '.')
        fi
        
        local POOL_JSON=$(jq -n \
                              --arg name "$POOL_NAME" \
                              --arg health "$POOL_HEALTH" \
                              --arg capacity "$POOL_CAPACITY" \
                              --arg fragmentation "$POOL_FRAGMENTATION" \
                              --arg scrub "$POOL_SCRUB_INFO" \
                              --argjson devices "${DEVICES_JSON:-[]}" \
                              '{
                                  name: $name, health: $health, lastScrub: $scrub,
                                  capacityPercent: ($capacity | tonumber),
                                  fragmentationPercent: ($fragmentation | tonumber),
                                  devices: $devices
                              }')
                               
        ALL_POOLS_JSON=$(echo "$ALL_POOLS_JSON" | jq ". + [$POOL_JSON]")
    done
    
    local PAYLOAD=$(jq -n \
                      --arg pve_host "$PVE_HOST_NAME" \
                      --argjson pools "$ALL_POOLS_JSON" \
                      '{
                          pveHost: $pve_host,
                          timestamp: (now | todateiso8601), 
                          pools: $pools
                       }')
                       
    print_debug "Итоговый JSON payload для отправки:" "$PAYLOAD"

    print_info "Отправка данных на API..."
    local RESPONSE_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
         --connect-timeout 15 \
         -H "Content-Type: application/json" \
         -d "$PAYLOAD" \
         "$API_URL")

    if [ "$RESPONSE_CODE" -ge 200 ] && [ "$RESPONSE_CODE" -lt 300 ]; then
        print_ok "Данные успешно отправлены на API (HTTP статус: $RESPONSE_CODE)."
    else
        print_error "Ошибка отправки данных на API (HTTP статус: $RESPONSE_CODE)."
    fi
    
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
        print_info "Расписание: ${C_WHITE}${CRON_SCHEDULE}${C_RESET} (каждый час)."
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
    echo "PVE-ZFS-Monitor: Скрипт для мониторинга состояния ZFS пулов и дисков."
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