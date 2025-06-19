#!/bin/bash

# ==============================================================================
# PVE-Checkup: Скрипт для аудита и выдачи рекомендаций по Proxmox VE
# Версия: 3.0 (с возможностью установки)
#
# GitHub: https://github.com/PahaKush/scripts
#
# ВНИМАНИЕ: Этот скрипт только читает данные и выдает рекомендации.
# Он не вносит никаких изменений в систему. Применяйте предложенные
# команды на свой страх и риск после их полного понимания.
# ==============================================================================

# ==============================================================================
#                      АВТОМАТИЧЕСКИЙ УСТАНОВЩИК
# ==============================================================================
# Этот блок выполняется, только если скрипт запущен через curl/wget | bash
# Проверяем, подключен ли стандартный ввод к терминалу.
if ! [ -t 0 ]; then

    # --- Настройки ---
    INSTALL_DIR="/opt/scripts"
    INSTALL_PATH="$INSTALL_DIR/pve-checkup.sh"
    # URL для скачивания "самого себя".
    SCRIPT_URL="https://raw.githubusercontent.com/PahaKush/scripts/main/pve-checkup.sh"

    # --- Цвета (локальные для установщика) ---
    C_RESET='\033[0m'
    C_RED='\033[0;31m'
    C_GREEN='\033[0;32m'
    C_YELLOW='\033[0;33m'
    C_WHITE='\033[1;37m'
    
    echo -e "${C_WHITE}Запуск установщика PVE-Checkup в автоматическом режиме...${C_RESET}"

    # Проверка на root
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${C_RED}Ошибка: Для установки скрипта в $INSTALL_DIR нужны права root.${C_RESET}"
        echo -e "${C_YELLOW}Пожалуйста, запустите команду установки через 'sudo bash' или от пользователя root.${C_RESET}"
        exit 1
    fi
    
    # Создаем директорию
    echo -e "Проверка/создание директории ${C_WHITE}$INSTALL_DIR${C_RESET}..."
    mkdir -p "$INSTALL_DIR"
    if [ $? -ne 0 ]; then
        echo -e "${C_RED}Не удалось создать директорию $INSTALL_DIR. Проверьте права.${C_RESET}"
        exit 1
    fi
    
    # Скачиваем скрипт
    echo -e "Скачивание последней версии в ${C_WHITE}$INSTALL_PATH${C_RESET}..."
    # Для скачивания используем curl, так как он уже используется в команде установки
    curl -fsSL "$SCRIPT_URL" -o "$INSTALL_PATH"
    
    # Проверяем успешность скачивания
    if [ $? -ne 0 ] || [ ! -s "$INSTALL_PATH" ]; then
        echo -e "${C_RED}Ошибка при скачивании скрипта. Проверьте URL и сетевое подключение.${C_RESET}"
        exit 1
    fi
    
    # Делаем скрипт исполняемым
    chmod +x "$INSTALL_PATH"
    if [ $? -ne 0 ]; then
        echo -e "${C_RED}Не удалось установить права на выполнение для $INSTALL_PATH.${C_RESET}"
        exit 1
    fi

    # Выводим финальное сообщение
    echo -e "\n${C_GREEN}Установка/обновление успешно завершено!${C_RESET}"
    echo "Скрипт сохранен и готов к использованию."
    echo
    echo "Для запуска аудита выполните:"
    echo -e "  ${C_WHITE}$INSTALL_PATH${C_RESET}"
    echo
    echo "Для получения справки по опциям (например, для неинтерактивного режима):"
    echo -e "  ${C_WHITE}$INSTALL_PATH --help${C_RESET}"

    # Завершаем работу, не выполняя основной код скрипта
    exit 0
fi

# ==============================================================================
#                      ОСНОВНОЙ КОД СКРИПТА НАЧИНАЕТСЯ ЗДЕСЬ
# ==============================================================================

# --- Переменная для режима отладки ---
DEBUG_MODE=0

# --- Цвета для вывода ---
C_RESET='\033[0m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_BLUE='\033[0;34m'
C_CYAN='\033[0;36m'
C_WHITE='\033[1;37m'
C_GRAY='\033[0;90m';

# --- Функции для вывода ---
print_header() {
    echo -e "\n${C_BLUE}======================================================================${C_RESET}"
    echo -e "${C_WHITE}$1${C_RESET}"
    echo -e "${C_BLUE}======================================================================${C_RESET}"
}

print_ok() {
    echo -e "[${C_GREEN}  OK  ${C_RESET}] $1"
}

print_warn() {
    echo -e "[${C_YELLOW} WARN ${C_RESET}] $1"
}

print_error() {
    echo -e "[${C_RED} ERROR ${C_RESET}] $1"
}

print_info() {
    echo -e "[${C_CYAN} INFO ${C_RESET}] $1"
}

print_rec() {
    echo -e "    ${C_YELLOW}└── РЕКОМЕНДАЦИЯ:${C_RESET} $1"
}

# --- Функция для отладочного вывода ---
print_debug() {
    local message=$1
    local data=$2
    if [ "$DEBUG_MODE" -eq 1 ]; then
        echo -e "${C_GRAY}    [DEBUG] $message${C_RESET}"
        # Если передан второй аргумент (данные), выводим его построчно
        if [ -n "$data" ]; then
            echo "$data" | while IFS= read -r line; do
                echo -e "${C_GRAY}      $line${C_RESET}" # Добавим отступ для данных
            done
        fi
    fi
}

# --- Проверка запуска от root ---
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${C_RED}Ошибка: Этот скрипт необходимо запускать от пользователя root.${C_RESET}"
    exit 1
fi

# --- Проверка наличия утилит ---
check_dependencies() {
    local MISSING_DEPS=0
    for cmd in smartctl arc_summary ss iostat jq bc; do
        if ! command -v $cmd &> /dev/null; then
            print_warn "Утилита '$cmd' не найдена. Некоторые проверки будут пропущены."
            MISSING_DEPS=1
        fi
    done
    if [ "$MISSING_DEPS" -eq 1 ]; then
        print_rec "Установите недостающие пакеты: apt install smartmontools zfsutils-linux iproute2 sysstat jq bc"
    fi
}

# ==============================================================================
#                            НАЧАЛО ПРОВЕРОК
# ==============================================================================

# --- 1. Система и репозитории ---
check_pve_system() {
    print_header "1. Система Proxmox и репозитории"
    pveversion
    if grep -q -r "^deb.*enterprise.proxmox.com" /etc/apt/sources.list*; then
        print_warn "Обнаружен активный 'enterprise' репозиторий. Может вызывать ошибки при обновлении без подписки."
    else
        print_ok "Enterprise репозиторий не активен."
    fi
    if ! grep -q -r "pve-no-subscription" /etc/apt/sources.list*; then
        print_warn "Не найден 'pve-no-subscription' репозиторий для получения обновлений."
    else
        print_ok "No-Subscription репозиторий настроен."
    fi
    if grep -q -r "pvetest" /etc/apt/sources.list*; then
        print_error "Обнаружен 'pvetest' репозиторий! Он нестабилен и не предназначен для продуктивных серверов."
    else
        print_ok "Тестовый репозиторий 'pvetest' не используется."
    fi
}

# --- 2. Кэш ZFS (ARC) ---
check_zfs_arc() {
    print_header "2. Настройки и эффективность кэша ZFS (ARC)"
    local TOTAL_RAM_GB=$(free -g | awk '/^Mem:/{print $2}')
    local ARC_MAX_BYTES=$(cat /sys/module/zfs/parameters/zfs_arc_max)
    print_debug "cat /sys/module/zfs/parameters/zfs_arc_max -> $ARC_MAX_BYTES"

    # Если ARC_MAX_BYTES равен 0, это значит, что используется дефолтное значение (50% RAM)
    if [ "$ARC_MAX_BYTES" -eq 0 ]; then
        print_warn "Лимит ARC не установлен (используется значение по умолчанию 50% ОЗУ). Это ОПАСНО для Proxmox."
        print_rec "Установите лимит, оставив достаточно памяти для ВМ. Например: echo 'options zfs zfs_arc_max=17179869184' > /etc/modprobe.d/zfs.conf && update-initramfs -u"
    else
        local ARC_MAX_GB=$((ARC_MAX_BYTES / 1024 / 1024 / 1024))
        print_info "Всего ОЗУ: ${TOTAL_RAM_GB} GB | Текущий лимит ARC: ${ARC_MAX_GB} GB"
        
        local DEFAULT_ARC_LIMIT=$((TOTAL_RAM_GB / 2))
        if [ "$ARC_MAX_GB" -ge "$DEFAULT_ARC_LIMIT" ]; then
            print_warn "Лимит ARC равен или больше 50% ОЗУ. Убедитесь, что для ВМ остается достаточно памяти."
        else
            print_ok "Лимит ARC установлен на безопасное значение."
        fi
    fi
    
    # Проверяем наличие файла со статистикой
    if [ ! -f "/proc/spl/kstat/zfs/arcstats" ]; then
        print_warn "Не найден файл статистики /proc/spl/kstat/zfs/arcstats. Проверка эффективности ARC невозможна."
        return
    fi

    # Читаем счетчики напрямую
    local HITS=$(awk '/^hits/ {print $3}' /proc/spl/kstat/zfs/arcstats)
    local MISSES=$(awk '/^misses/ {print $3}' /proc/spl/kstat/zfs/arcstats)
    print_debug "Из /proc/spl/kstat/zfs/arcstats: HITS=$HITS, MISSES=$MISSES"

    # Убеждаемся, что оба значения - это числа
    if [[ ! "$HITS" =~ ^[0-9]+$ ]] || [[ ! "$MISSES" =~ ^[0-9]+$ ]]; then
        print_warn "Не удалось получить корректные числовые значения для hits/misses из arcstats."
        return
    fi
    
    local TOTAL_ACCESSES=$((HITS + MISSES))
    
    # Проверяем только если была значительная активность
    if [ "$TOTAL_ACCESSES" -gt 1000 ]; then
        # Используем bc для вычислений с плавающей точкой
        ARC_HIT_PERCENT=$(echo "scale=2; ($HITS / $TOTAL_ACCESSES) * 100" | bc | cut -d'.' -f1)
        
        if [ "$ARC_HIT_PERCENT" -lt 90 ]; then
            print_warn "ARC Hit Ratio ниже 90% (${ARC_HIT_PERCENT}%). Это может говорить о нехватке памяти для кэша."
            print_rec "Рассмотрите возможность увеличения лимита ARC в /etc/modprobe.d/zfs.conf"
        else
            print_ok "ARC Hit Ratio высокий (${ARC_HIT_PERCENT}%)."
        fi
    else
        print_info "Недостаточно активности ZFS для расчета ARC Hit Ratio."
    fi
}

# --- 3. Углубленный анализ ZFS пулов ---
check_zfs_pools_deep() {
    print_header "3. Углубленный анализ ZFS пулов"
    # Проверяем, есть ли вообще ZFS пулы
    if ! zpool list -H -o name 2>/dev/null | grep -q .; then
        print_info "Пулы ZFS не найдены."
        return
    fi

    if ! zpool status -x | grep -q "all pools are healthy"; then
        print_error "Обнаружены проблемы с ZFS пулами! Вывод 'zpool status':"
        zpool status
    else
        print_ok "Все пулы находятся в состоянии 'healthy' (zpool status -x)."
    fi

    zpool list -H -o name | while read -r ZPOOL; do
        echo
        print_info "Анализ пула: ${C_WHITE}${ZPOOL}${C_RESET}"
        
        # Проверка заполненности
        CAPACITY=$(zpool list -H -o capacity "$ZPOOL" | tr -d '%')
        print_debug "zpool list -H -o capacity $ZPOOL -> ${CAPACITY}%"
        if [ -n "$CAPACITY" ] && [ "$CAPACITY" -gt 80 ]; then
            print_warn "Пул $ZPOOL заполнен на ${CAPACITY}%. При заполнении > 80% производительность ZFS может снижаться."
        elif [ -n "$CAPACITY" ]; then
            print_ok "Заполнение пула ${CAPACITY}% (в пределах нормы)."
        fi

        # Проверка фрагментации
        FRAGMENTATION=$(zpool list -H -o frag "$ZPOOL" | tr -d '%')
        print_debug "zpool list -H -o frag $ZPOOL -> ${FRAGMENTATION}%"
        if [ -n "$FRAGMENTATION" ] && [ "$FRAGMENTATION" -gt 35 ]; then
            print_warn "Фрагментация пула $ZPOOL составляет ${FRAGMENTATION}%. Высокая фрагментация может снижать производительность."
        elif [ -n "$FRAGMENTATION" ]; then
            print_ok "Фрагментация пула ${FRAGMENTATION}% (в пределах нормы)."
        fi

        # Проверка autotrim
        AUTOTRIM=$(zpool get -H -o value autotrim $ZPOOL)
        print_debug "zpool get autotrim $ZPOOL -> $AUTOTRIM"
        if [ "$AUTOTRIM" == "off" ]; then
            # Проверяем, есть ли SSD в пуле, чтобы не давать лишних рекомендаций для HDD
            if zpool status $ZPOOL | grep -q -E 'nvme-|ata-.*SSD'; then
                print_info "Опция 'autotrim' для пула $ZPOOL (на SSD) выключена. Рекомендуется включить."
                print_rec "Для включения: zpool set autotrim=on $ZPOOL"
            else
                print_info "Опция 'autotrim' для пула $ZPOOL (на HDD) выключена (это нормально)."
            fi
        else
            print_ok "Опция 'autotrim' для пула $ZPOOL включена."
        fi

        # Проверка ошибок чтения/записи
        ERRORS=$(zpool status $ZPOOL | awk '/^  (ata-|nvme-)/{ if ($3>0 || $4>0 || $5>0) print $1 }')
        print_debug "Поиск ошибок в 'zpool status $ZPOOL' -> '$ERRORS'"
        [ -n "$ERRORS" ] && print_error "Обнаружены ошибки чтения/записи/контрольных сумм на дисках в пуле $ZPOOL!" || print_ok "Ошибки чтения/записи/контрольных сумм не обнаружены."
        
        # Получаем ashift для всего пула
        POOL_ASHIFT=$(zpool get -Hp -o value ashift "$ZPOOL" 2>/dev/null)
        print_debug "zpool get -Hp -o value ashift $ZPOOL -> '$POOL_ASHIFT'"

        if [ -n "$POOL_ASHIFT" ]; then
            if [ "$POOL_ASHIFT" -lt 12 ]; then
                print_error "КРИТИЧЕСКАЯ ОШИБКА: Пул $ZPOOL имеет ashift=${POOL_ASHIFT}. Рекомендуется 12 или 13 для ВСЕХ современных дисков (HDD/SSD/NVMe)."
                print_rec "Это нельзя исправить без пересоздания пула. Производительность будет сильно снижена."
            else
                 print_ok "Ashift пула $ZPOOL (${POOL_ASHIFT}) корректен."
            fi
        else
            print_warn "Не удалось определить ashift для пула $ZPOOL."
        fi
        
        print_info "Проверка SMART для дисков пула $ZPOOL..."
        # Получаем список физических устройств из zpool status
        zpool status $ZPOOL | grep -E -- '^\s+(ata-|nvme-|scsi-)' | awk '{print $1}' | while read -r DISK_ID; do
            DEVICE_PATH="/dev/disk/by-id/$DISK_ID"
            
            if [ ! -e "$DEVICE_PATH" ]; then print_warn "Не удалось найти устройство $DEVICE_PATH для диска $DISK_ID."; continue; fi
            
            # Проверка SMART
            if command -v smartctl &> /dev/null; then
                SMART_OUTPUT=$(smartctl -a "$DEVICE_PATH" 2>/dev/null)
                if [ -z "$SMART_OUTPUT" ]; then 
                    print_warn "Не удалось получить SMART-информацию для $DISK_ID. Возможно, требуется указать тип устройства (-d sat)."
                    continue
                fi

                SMART_STATUS=$(echo "$SMART_OUTPUT" | grep 'SMART overall-health' | awk '{print $6}')
                print_debug "smartctl -H $DEVICE_PATH -> статус: '$SMART_STATUS'"

                if [ -n "$SMART_STATUS" ] && [ "$SMART_STATUS" != "PASSED" ]; then
                    print_error "SMART-тест для диска $DISK_ID не пройден! Статус: $SMART_STATUS"
                else
                    print_ok "SMART-статус диска $DISK_ID: PASSED."

                    # Дополнительная проверка критичных атрибутов
                    REALLOC=$(echo "$SMART_OUTPUT" | grep "Reallocated_Sector_Ct" | awk '{print $10}')
                    PENDING=$(echo "$SMART_OUTPUT" | grep "Current_Pending_Sector" | awk '{print $10}')
                    [ -n "$REALLOC" ] && [ "$REALLOC" -gt 0 ] && print_warn "    - Диск $DISK_ID имеет $REALLOC переназначенных секторов. Это предвестник сбоя."
                    [ -n "$PENDING" ] && [ "$PENDING" -gt 0 ] && print_warn "    - Диск $DISK_ID имеет $PENDING нестабильных секторов. Это предвестник сбоя."
                fi
            fi
        done
    done
}

# --- 4. Проверки, специфичные для Proxmox ---
check_pve_specifics() {
    print_header "4. Специфичные проверки Proxmox"

    # Статус кластера
    if [ -f "/etc/pve/corosync.conf" ]; then
        if pvecm status | grep -q "Quorate: Yes"; then
            print_ok "Кластер имеет кворум."
        else
            print_error "КЛАСТЕР НЕ ИМЕЕТ КВОРУМА! Это критическая ошибка."
            pvecm status
        fi
    else
        print_info "Система работает в однонодовом режиме (не в кластере)."
    fi

    # Статус хранилищ
    print_info "Проверка статуса хранилищ..."
    if ! command -v jq &> /dev/null; then
        print_warn "Утилита 'jq' не найдена. Проверка статуса хранилищ через API пропущена."
    else
        local INACTIVE_STORAGES=""
        # pvesm status не поддерживает JSON, парсим текстовый вывод
        pvesm status | awk 'NR>1 && $3 != "active" {print $1}' | while read -r STORAGE; do
            INACTIVE_STORAGES="$INACTIVE_STORAGES $STORAGE"
        done
        
        if [ -n "$INACTIVE_STORAGES" ]; then
            print_warn "Хранилища '$INACTIVE_STORAGES' неактивны или недоступны."
        else
            print_ok "Все хранилища активны и доступны."
        fi
    fi

    # Статус брандмауэра
    if pve-firewall status | grep -q "Status: disabled"; then
        print_warn "Брандмауэр Proxmox отключен на уровне датацентра."
        print_rec "Если это не сделано намеренно, рассмотрите возможность его включения."
    else
        print_ok "Брандмауэр Proxmox включен."
    fi
    
    # Статус бэкапов
    print_info "Проверка статуса последних бэкапов (за последние 3 дня)..."

    if ! command -v jq &> /dev/null; then
        print_warn "Утилита 'jq' не найдена. Проверка бэкапов через API пропущена."
        return
    fi

    # Получаем список всех хранилищ из текстового вывода pvesm status
    local STORAGE_IDS=$(pvesm status | awk 'NR>1 {print $1}')
    local BACKUP_PATHS=""
    
    for STORAGE_ID in $STORAGE_IDS; do
        print_debug "Проверка хранилища: $STORAGE_ID"
        
        local STORAGE_CONFIG_JSON=$(pvesh get /storage/"$STORAGE_ID" --output-format json 2>/dev/null)
        if [ -z "$STORAGE_CONFIG_JSON" ]; then continue; fi
        
        print_debug "Конфигурация для '$STORAGE_ID':" "$STORAGE_CONFIG_JSON"

        local IS_DISABLED=$(echo "$STORAGE_CONFIG_JSON" | jq -r '(.disable // 0)')
        local HAS_BACKUP_CONTENT=$(echo "$STORAGE_CONFIG_JSON" | jq -r '.content' | grep -c "backup")

        if [ "$IS_DISABLED" -eq 0 ] && [ "$HAS_BACKUP_CONTENT" -gt 0 ]; then
            local STORAGE_PATH=$(echo "$STORAGE_CONFIG_JSON" | jq -r '.path')
            if [ -n "$STORAGE_PATH" ] && [ "$STORAGE_PATH" != "null" ]; then
                print_debug "Хранилище '$STORAGE_ID' подходит. Путь: $STORAGE_PATH"
                BACKUP_PATHS="${BACKUP_PATHS}${STORAGE_PATH}\n"
            fi
        else
            print_debug "Хранилище '$STORAGE_ID' пропущено (Disabled: ${IS_DISABLED}, Backup Content: ${HAS_BACKUP_CONTENT})."
        fi
    done
    
    BACKUP_PATHS=$(echo -e "${BACKUP_PATHS}" | sed '/^$/d')

    if [ -z "$BACKUP_PATHS" ]; then
        print_info "Не найдено активных хранилищ с разрешенным контентом 'backup'."
        return
    fi
    print_debug "Итоговые пути для поиска бэкапов:\n${BACKUP_PATHS}"

    VM_LIST=$( (pct list | awk 'NR>1 {print $1}'; qm list | awk 'NR>1 {print $1}') 2>/dev/null | sort -u )
    
    for VMID in $VM_LIST; do
        local LATEST_LOG_FOUND=0 LATEST_LOG_PATH=""
        
        while IFS= read -r path; do
            [ -z "$path" ] && continue

            local CURRENT_LOG=$(find "$path/dump" -maxdepth 1 -type f \( -name "vzdump-qemu-${VMID}-*.log" -o -name "vzdump-lxc-${VMID}-*.log" \) -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n 1 | cut -d' ' -f2-)
            if [ -n "$CURRENT_LOG" ]; then
                if [ -z "$LATEST_LOG_PATH" ] || [ "$(stat -c %Y "$CURRENT_LOG")" -gt "$(stat -c %Y "$LATEST_LOG_PATH")" ]; then
                    LATEST_LOG_PATH=$CURRENT_LOG
                fi
                LATEST_LOG_FOUND=1
            fi
        done < <(echo -e "${BACKUP_PATHS}")

        if [ "$LATEST_LOG_FOUND" -eq 1 ]; then
            print_debug "Анализ самого свежего лога для VMID ${VMID}: ${LATEST_LOG_PATH}"
            local LOG_MOD_TIME=$(stat -c %Y "$LATEST_LOG_PATH")
            local THREE_DAYS_AGO=$(date -d "3 days ago" +%s)
            
            if grep -q -i -E "ERROR|FAILED" "$LATEST_LOG_PATH"; then
                print_error "Последний бэкап для ВМ/КТ $VMID завершился с ОШИБКОЙ."
            elif [ "$LOG_MOD_TIME" -lt "$THREE_DAYS_AGO" ]; then
                print_warn "Последний успешный бэкап для ВМ/КТ $VMID был более 3 дней назад."
            else
                print_ok "Бэкап для ВМ/КТ $VMID свежий и успешный."
            fi
        else
            print_warn "Не найдены бэкапы для ВМ/КТ $VMID ни на одном из хранилищ."
        fi
    done
}

# --- 5. Проверка производительности ---
check_performance() {
    print_header "5. Проверка производительности"
    # Загрузка CPU
    local CPU_CORES=$(nproc)
    local LOAD_AVG_5M=$(awk '{print $2}' /proc/loadavg)
    print_info "Количество ядер CPU: $CPU_CORES | Load Average (5 min): $LOAD_AVG_5M"
    if (( $(echo "$LOAD_AVG_5M > $CPU_CORES" | bc -l) )); then
        print_warn "Высокая загрузка CPU! Load Average за 5 минут превышает количество ядер."
    else
        print_ok "Загрузка CPU в пределах нормы."
    fi

    # Использование SWAP
    local SWAP_USED=$(free | awk '/^Swap:/{print $3}')
    local SWAP_TOTAL=$(free | awk '/^Swap:/{print $2}')
    if [ "$SWAP_TOTAL" -gt 0 ] && [ "$SWAP_USED" -gt 0 ]; then
        print_warn "Используется SWAP (${SWAP_USED}k из ${SWAP_TOTAL}k). Это может указывать на нехватку оперативной памяти."
    else
        print_ok "SWAP не используется."
    fi

    # I/O Wait
    if command -v iostat &> /dev/null && command -v jq &> /dev/null; then
        local IOSTAT_JSON=$(iostat -c -o JSON)
        local IO_WAIT=$(echo "$IOSTAT_JSON" | jq -r '.sysstat.hosts[0].statistics[0]."avg-cpu".iowait')
        
        local IO_WAIT_INT=$(echo "$IO_WAIT" | cut -d'.' -f1)

        print_info "Средний I/O Wait (с момента загрузки): ${IO_WAIT}%"
        if [ "$IO_WAIT_INT" -gt 10 ]; then
            print_warn "Высокий I/O Wait! Дисковая подсистема является узким местом."
            print_rec "Проверьте 'iotop' или 'iostat -x 1' для определения процесса, нагружающего диски."
        else
            print_ok "I/O Wait в пределах нормы."
        fi
    fi
}

# --- 6. Проверка сети ---
check_network() {
    print_header "6. Проверка сети"
    local BRIDGE="vmbr0"
    if ip link show $BRIDGE &>/dev/null; then
        ! ip link show $BRIDGE | grep -q "state UP" && print_error "Интерфейс $BRIDGE не активен (DOWN)." || print_ok "Интерфейс $BRIDGE активен (UP)."
        ! ip addr show $BRIDGE | grep -q "inet " && print_error "На интерфейсе $BRIDGE отсутствует IPv4-адрес." || print_ok "IPv4-адрес на $BRIDGE настроен."
    else
        print_error "Основной сетевой мост $BRIDGE не найден."
    fi
    local GW=$(ip route | awk '/default/ {print $3}')
    if [ -n "$GW" ]; then
        ping -c 1 -W 1 "$GW" &>/dev/null && print_ok "Шлюз ($GW) доступен." || print_error "Шлюз ($GW) не пингуется."
    else
        print_error "Шлюз по умолчанию не определен."
    fi
    host proxmox.com &>/dev/null && print_ok "DNS-разрешение работает." || print_error "DNS-разрешение не работает."
}

# --- 7.1 В конце check_security ---
check_pve_users() {
    print_info "Проверка пользователей Proxmox на наличие 2FA..."

    if ! command -v jq &> /dev/null; then
        print_warn "Проверка 2FA пропущена, так как утилита 'jq' не найдена."
        return
    fi

    # Получаем список всех пользователей, кроме системных
    local USERS=$(pveum user list --output-format=json-pretty | jq -r '.[] | select(.userid | test("@pve$|@pam$") | not) | .userid')
    
    if [ -z "$USERS" ]; then
        print_info "Дополнительные пользователи не найдены (кроме системных)."
        return
    fi
    
    for USER in $USERS; do
        # Проверяем, есть ли у пользователя настроенные ключи TFA
        if pveum user tfa list "$USER" | grep -q "entry"; then
            print_ok "Пользователь '$USER' использует двухфакторную аутентификацию (2FA)."
        else
            print_warn "Пользователь '$USER' НЕ использует 2FA. Это снижает безопасность."
            print_rec "Настройте 2FA для этого пользователя в 'Datacenter -> Permissions -> Two Factor'."
        fi
    done
}

# --- 7. Проверка безопасности ---
check_security() {
    print_header "7. Проверка безопасности"
    if systemctl list-unit-files | grep -q "fail2ban.service"; then
        systemctl is-active --quiet fail2ban && print_ok "Служба Fail2ban установлена и активна." || print_warn "Служба Fail2ban установлена, но не активна."
    else
        print_warn "Служба Fail2ban не установлена. Рекомендуется: apt install fail2ban"
    fi
    local SSH_CONFIG="/etc/ssh/sshd_config"
    grep -qE '^[[:space:]]*PermitRootLogin[[:space:]]+yes' "$SSH_CONFIG" && print_warn "Вход по SSH для root разрешен. Рекомендуется отключить." || print_ok "Вход по SSH для root запрещен."
    grep -qE '^[[:space:]]*PasswordAuthentication[[:space:]]+yes' "$SSH_CONFIG" && print_warn "Аутентификация по паролю в SSH разрешена. Рекомендуется использовать ключи." || print_ok "Аутентификация по паролю в SSH отключена."
    print_info "Проверка открытых портов..."
    local EXPECTED_PORTS=(22 8006 111)
    local LISTENING_PORTS=($(ss -tuln | grep -v '127.0.0.1' | grep -v '::1' | awk 'NR>1 {print $5}' | sed 's/.*://' | sort -uV))
    local UNEXPECTED_PORTS=""
    for PORT in "${LISTENING_PORTS[@]}"; do
        local IS_EXPECTED=0
        for EXPECTED in "${EXPECTED_PORTS[@]}"; do [ "$PORT" -eq "$EXPECTED" ] && IS_EXPECTED=1 && break; done
        [ "$IS_EXPECTED" -eq 0 ] && UNEXPECTED_PORTS="$UNEXPECTED_PORTS $PORT"
    done
    [ -n "$UNEXPECTED_PORTS" ] && print_warn "Обнаружены дополнительные открытые порты:${UNEXPECTED_PORTS}." || print_ok "Неожиданные открытые порты не обнаружены."

    check_pve_users
}

# --- 8. Проверка дисков ВМ ---
check_vm_disks() {
    print_header "8. Диски виртуальных машин"
    print_info "Проверка на использование неэффективных форматов (qcow2) на ZFS..."

    local FOUND_QCOW2=0
    for VMID in $(qm list | awk 'NR>1 {print $1}'); do
        # Используем qm config, так как он не требует jq и работает на всех версиях
        local CONFIG_TEXT=$(qm config "$VMID" 2>/dev/null)
        # Если не удалось получить конфиг, пропускаем
        if [ -z "$CONFIG_TEXT" ]; then continue; fi
        
        local VM_NAME=$(echo "$CONFIG_TEXT" | grep -oP 'name: \K.*')
        
        # Ищем 'qcow2' только в валидных строках дисков
        local DISK_CONFIGS=$(echo "$CONFIG_TEXT" | grep -oP '^(ide|scsi|sata|virtio)[0-9]+: .*')
        print_debug "ВМ $VMID диски -> $DISK_CONFIGS"

        if echo "$DISK_CONFIGS" | grep -q 'qcow2'; then
            print_warn "ВМ ${VMID} (${VM_NAME}) использует диск в формате qcow2. Это неоптимально для ZFS."
            print_rec "Рассмотрите возможность конвертации диска в raw формат (zvol)."
            FOUND_QCOW2=1
        fi
    done
    [ "$FOUND_QCOW2" -eq 0 ] && print_ok "Не найдено ВМ с дисками qcow2 на ZFS."
}

# --- 9. Бэкап хоста ---
check_host_backup() {
    print_header "9. Автоматический бэкап конфигурации хоста"
    if [ -f "/opt/scripts/backup_etc.sh" ]; then
        print_ok "Найден скрипт бэкапа конфигурации хоста."
        if crontab -l 2>/dev/null | grep -q "/opt/scripts/backup_etc.sh" || grep -q -r "/opt/scripts/backup_etc.sh" /etc/cron*; then
             print_ok "Скрипт бэкапа хоста добавлен в cron."
        else
             print_warn "Скрипт бэкапа хоста существует, но не найден в cron."
        fi
    else
        print_info "Автоматический бэкап конфигурации хоста (/etc) не настроен."
    fi
}

# --- 10. Проверка синхронизации времени (NTP) ---
check_ntp_sync() {
    print_header "10. Проверка синхронизации времени (NTP)"
    if command -v timedatectl &> /dev/null; then
        if timedatectl status | grep -q "System clock synchronized: yes"; then
            print_ok "Системное время синхронизировано через NTP."
            local NTP_SERVER=$(timedatectl status | grep "NTP server:" | awk '{print $3}')
            [ -n "$NTP_SERVER" ] && print_info "Используемый NTP сервер: $NTP_SERVER"
        else
            print_warn "Системное время НЕ синхронизировано. Это может вызвать проблемы с логами и кластером."
            print_rec "Убедитесь, что служба systemd-timesyncd активна: systemctl status systemd-timesyncd"
        fi
    elif command -v ntpq &> /dev/null; then
         # Для старых систем с ntpd
         if ntpq -p | grep -q "^\*"; then
             print_ok "Системное время синхронизировано через NTP (ntpd)."
         else
             print_warn "Системное время НЕ синхронизировано (ntpd)."
         fi
    else
        print_info "Не удалось определить статус синхронизации времени (не найдены timedatectl или ntpq)."
    fi
}

# --- 11. Проверка обновлений ядра и перезагрузки ---
check_kernel_reboot() {
    print_header "11. Проверка обновлений ядра"
    local RUNNING_KERNEL=$(uname -r)
    
    # Ищем самый свежий файл ядра в /boot.
    local LATEST_KERNEL_FILE=$(find /boot -name "vmlinuz-*" | sort -V | tail -n 1)
    
    # Извлекаем версию из имени файла
    local LATEST_INSTALLED_KERNEL_VERSION=$(basename "$LATEST_KERNEL_FILE" | sed 's/^vmlinuz-//')

    print_info "Текущее запущенное ядро: $RUNNING_KERNEL"
    
    if [ -n "$LATEST_INSTALLED_KERNEL_VERSION" ]; then
        print_info "Последняя установленная версия ядра: $LATEST_INSTALLED_KERNEL_VERSION"

        if [ "$RUNNING_KERNEL" != "$LATEST_INSTALLED_KERNEL_VERSION" ]; then
            print_warn "Запущенное ядро не является последним установленным. Требуется перезагрузка для применения обновлений."
            print_rec "Запланируйте перезагрузку сервера командой 'reboot'."
        else
            print_ok "Система работает на последней установленной версии ядра."
        fi
    else
        print_error "Не удалось определить последнюю установленную версию ядра."
    fi

    if [ -f /var/run/reboot-required ]; then
        print_warn "Система сигнализирует о необходимости перезагрузки (файл /var/run/reboot-required существует)."
    fi
}

# --- 12. Проверка QEMU Guest Agent ---
check_qemu_agent() {
    print_header "12. Проверка QEMU Guest Agent"
    print_info "Проверка статуса гостевого агента на запущенных ВМ..."

    # Получаем список только запущенных ВМ
    local RUNNING_VMS=$(qm list | awk 'NR>1 && $3=="running" {print $1}')

    if [ -z "$RUNNING_VMS" ]; then
        print_info "Нет запущенных виртуальных машин для проверки."
        return
    fi

    # Проверяем наличие jq один раз перед циклом
    if ! command -v jq &> /dev/null; then
        print_error "Утилита 'jq' не найдена. Эта проверка требует jq для работы с API. Пропускаем..."
        return
    fi

    for VMID in $RUNNING_VMS; do
        local CONFIG_JSON=$(pvesh get /nodes/"$(hostname)"/qemu/"$VMID"/config --output-format json 2>/dev/null)
        local VM_NAME=$(echo "$CONFIG_JSON" | jq -r '.name // "unknown"')
        local AGENT_ENABLED=$(echo "$CONFIG_JSON" | jq -r '.agent // "0"') # Дефолт '0', если не задано

        echo
        print_info "Анализ ВМ ${VMID} (${VM_NAME})..."

        if [[ "$AGENT_ENABLED" != "1" && ! "$AGENT_ENABLED" =~ enabled=1 ]]; then
            print_warn "Гостевой агент НЕ включен в конфигурации."
            print_rec "Включите его на вкладке 'Options' -> 'QEMU Guest Agent'."
            continue
        fi

        # 1. Проверяем базовую доступность через ping
        local PING_OUTPUT=$(timeout 3 qm agent "$VMID" ping 2>&1)
        local PING_EXIT_CODE=$?
        print_debug "qm agent $VMID ping -> Код выхода: $PING_EXIT_CODE, Ответ: '${PING_OUTPUT//$'\n'/ }'"

        if [ $PING_EXIT_CODE -eq 0 ]; then
            # Пинг успешен, теперь запрашиваем информацию
            local INFO_JSON INFO_EXIT_CODE AGENT_VERSION AGENT_IP
            
            INFO_JSON=$(timeout 3 qm agent "$VMID" info 2>/dev/null)
            INFO_EXIT_CODE=$?
            print_debug "qm agent $VMID info -> Код выхода: $INFO_EXIT_CODE, JSON: '${INFO_JSON//$'\n'/ }'"

            if [ $INFO_EXIT_CODE -eq 0 ] && [ -n "$INFO_JSON" ]; then
                # Версия агента находится в поле .version
                AGENT_VERSION=$(echo "$INFO_JSON" | jq -r '.version // ""')

                # Получаем IP-адреса
                local IP_JSON=$(timeout 3 qm agent "$VMID" network-get-interfaces 2>/dev/null)

                # Извлекаем первый "не-локальный" IPv4 адрес
                AGENT_IP=$(echo "$IP_JSON" | jq -r '[.[] | select(.name | test("loopback|lo") | not) | .["ip-addresses"][]? | select(."ip-address-type" == "ipv4") | ."ip-address"] | first // ""')
                
                print_ok "Агент отвечает (Версия: ${AGENT_VERSION:-не определена}, IP: ${AGENT_IP:-не определен})."
            else
                print_error "АНОМАЛИЯ! Пинг к агенту успешен, но команда 'info' не вернула данные."
                print_rec "Это указывает на \"зависшую\" службу агента. Перезапустите 'QEMU Guest Agent' внутри ВМ."
            fi
        
        elif [ $PING_EXIT_CODE -eq 124 ]; then
            print_error "Агент НЕ отвечает (тайм-аут 3 сек)."
            print_rec "Проверьте брандмауэр внутри ВМ или статус службы 'QEMU Guest Agent'."
        else
            # Пинг провалился с другой ошибкой
            if echo "$PING_OUTPUT" | grep -qi "guest agent is not running"; then
                print_error "Агент НЕ запущен (явный ответ от PVE)."
                print_rec "Запустите службу 'QEMU Guest Agent' ('qemu-ga') внутри гостевой ОС."
            else
                local ERROR_MSG
                ERROR_MSG=$(echo "$PING_OUTPUT" | tr -d '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                print_error "Не удалось связаться с агентом (Код: $PING_EXIT_CODE). Ответ: '${ERROR_MSG:-пусто}'"
            fi
        fi
    done
}

# --- 13. Углубленная проверка конфигурации ВМ и КТ (ИНТЕРАКТИВНОСТЬ ПО УМОЛЧАНИЮ) ---
check_vm_ct_tuning() {
    # Принимаем аргумент с ID ВМ для неинтерактивной проверки
    local DB_VMS_ARG=$1
    local SKIP_DB_DETAILS_PARAM=$2

    print_header "13. Углубленная проверка конфигурации ВМ и Контейнеров"

    # --- Проверка Виртуальных Машин ---
    local VM_IDS=$(qm list | awk 'NR>1 {print $1}')

    if [ -z "$VM_IDS" ]; then
        print_info "Виртуальные машины не найдены."
    else
        # Определяем, нужно ли вообще пропускать углубленный анализ
        local SHOULD_SKIP_ALL_DB_CHECKS_GLOBALLY=0
        if [ -z "$DB_VMS_ARG" ] && [ "$SKIP_DB_DETAILS_PARAM" -eq 1 ]; then
            SHOULD_SKIP_ALL_DB_CHECKS_GLOBALLY=1
            print_info "Углубленный анализ ВМ для серверов БД будет пропущен (указана опция --skip-db-details)."
        fi

        # Проверяем наличие jq один раз перед циклом
        if ! command -v jq &> /dev/null; then
            print_error "Утилита 'jq' не найдена. Эта проверка требует jq для работы с API. Пропускаем..."
            return
        fi

        for VMID in $VM_IDS; do
            # Получаем актуальную информацию о ВМ
            local VM_INFO=$(qm list | grep " $VMID ")
            local VM_NAME=$(echo "$VM_INFO" | awk '{print $2}')
            local VM_STATUS=$(echo "$VM_INFO" | awk '{print $3}')

            echo
            print_info "Анализ ВМ ${VMID} (${VM_NAME}) - Статус: $VM_STATUS"
            
            # --- Получаем БУДУЩУЮ конфигурацию из /config API для всех проверок ---
            local FUTURE_CONFIG_JSON=$(pvesh get /nodes/"$(hostname)"/qemu/"$VMID"/config --output-format json 2>/dev/null)
            if [ -z "$FUTURE_CONFIG_JSON" ]; then print_error "Не удалось получить конфигурацию для ВМ $VMID."; continue; fi
            print_debug "Будущая конфигурация (из /config API):" "$FUTURE_CONFIG_JSON"

            # --- Общие проверки производительности (на основе JSON) ---
            
            # 1. Проверка типа CPU
            local CPU_TYPE=$(echo "$FUTURE_CONFIG_JSON" | jq -r '.cpu // "kvm64"')
            if [ "$CPU_TYPE" == "kvm64" ]; then
                print_warn "CPU Type: 'kvm64'. Это сильно снижает производительность."
                print_rec "Используйте 'x86-64-v2-AES' или 'host' (для макс. производительности)."
            elif [ "$CPU_TYPE" != "host" ]; then
                print_ok "CPU Type: '$CPU_TYPE' (хороший выбор для совместимости)."
            else
                print_ok "CPU Type: 'host' (оптимально для производительности, но не для миграции)."
            fi
            
            # 2. Проверка SCSI контроллера
            local SCSI_CONTROLLER=$(echo "$FUTURE_CONFIG_JSON" | jq -r '.scsihw // "lsi"')
            if [[ "$SCSI_CONTROLLER" == "virtio-scsi-single" || "$SCSI_CONTROLLER" == "virtio-scsi-pci" ]]; then
                print_ok "SCSI Controller: '$SCSI_CONTROLLER' (оптимально)."
            else
                print_warn "SCSI Controller: '$SCSI_CONTROLLER'. Рекомендуется 'VirtIO SCSI Single'."
                print_rec "Измените на вкладке 'Hardware' -> SCSI Controller."
            fi
            
            # 3. Проверка сетевой карты
            local NET_CONFIG_VALUES=$(echo "$FUTURE_CONFIG_JSON" | jq -r 'to_entries | .[] | select(.key | test("^net[0-9]+$")) | .value')
            if [ -n "$NET_CONFIG_VALUES" ]; then
                if echo "$NET_CONFIG_VALUES" | grep -v -q "virtio"; then
                     print_warn "Обнаружена сетевая карта не-VirtIO. Рекомендуется использовать VirtIO."
                else
                     print_ok "Все сетевые карты используют модель VirtIO (оптимально)."
                fi
            fi
            
            # 4. Проверка io_thread
            local IO_THREAD_DISKS=$(echo "$FUTURE_CONFIG_JSON" | jq -r 'to_entries | .[] | select(.key | test("^(virtio|scsi)[0-9]+$")) | .value')
            print_debug "Диски, проверяемые на iothread:" "$IO_THREAD_DISKS"
            if [ -n "$IO_THREAD_DISKS" ]; then
                # Проверяем, есть ли хоть один диск без iothread=1, который не является CD-ROM
                if echo "$IO_THREAD_DISKS" | grep -v 'media=cdrom' | grep -v -q 'iothread=1'; then
                    print_warn "Опция 'iothread=1' используется не для всех дисков VirtIO/SCSI. Ее включение может повысить IOPS."
                    print_rec "Включите 'IO Thread' в опциях каждого диска на вкладке 'Hardware'."
                else
                    print_ok "Опция 'iothread=1' используется для всех дисков VirtIO/SCSI (оптимально)."
                fi
            fi

            # 5. Проверка Ballooning
            local BALLOON_VALUE=$(echo "$FUTURE_CONFIG_JSON" | jq -r '.balloon // "default_on"')
            if [ "$BALLOON_VALUE" != "0" ]; then
                print_warn "Включен Memory Ballooning. Для ВМ с БД или 1С рекомендуется его отключить (установить 0) и выделить фиксированный объем памяти."
            fi

            # Гибридная логика для определения, нужно ли проводить углубленную проверку
            local PERFORM_DB_CHECK=0
            if [ -n "$DB_VMS_ARG" ]; then
                # НЕИНТЕРАКТИВНЫЙ РЕЖИМ: Проверяем, есть ли ID текущей ВМ в списке
                if [[ ",$DB_VMS_ARG," == *",$VMID,"* ]]; then
                    PERFORM_DB_CHECK=1
                    echo -e "    ${C_CYAN}└── ВМ найдена в списке для углубленного анализа (--db-vms)...${C_RESET}"
                fi
            elif [ "$SHOULD_SKIP_ALL_DB_CHECKS_GLOBALLY" -eq 0 ]; then 
                # ИНТЕРАКТИВНЫЙ РЕЖИМ ПО УМОЛЧАНИЮ: Задаем вопрос пользователю
                read -p "    Провести углубленный анализ для ВМ ${VMID} (${VM_NAME}) как для сервера БД (MS SQL, 1С)? (y/n) " -n 1 -r < /dev/tty; echo
                if [[ $REPLY =~ ^[Yy]$ ]]; then
                    PERFORM_DB_CHECK=1
                fi
            fi

            # Углубленные проверки для ВМ с БД (1С/SQL)
            if [ "$PERFORM_DB_CHECK" -eq 1 ]; then
                local ALL_DISK_CONFIGS=$(echo "$FUTURE_CONFIG_JSON" | jq -r 'to_entries | .[] | select(.key | test("^(ide|scsi|sata|virtio)[0-9]+$")) | .key + ":" + .value')
                
                print_debug "Все диски для углубленного анализа:" "$ALL_DISK_CONFIGS"

                # Проверка Discard/TRIM
                # Ищем диски на zfspool, у которых нет discard=on
                if echo "$ALL_DISK_CONFIGS" | grep -v 'media=cdrom' | grep -v -q "discard=on"; then
                    print_warn "Опция 'discard=on' (TRIM) не включена для всех дисков. Важно для SSD и Thin-хранилищ."
                else
                    print_ok "Опция 'discard=on' (TRIM) включена для всех дисков."
                fi

                # Проверка Async IO (io_uring)
                if echo "$ALL_DISK_CONFIGS" | grep -v 'media=cdrom' | grep -v -q 'aio=io_uring'; then
                    print_warn "Режим 'Async IO' не установлен в 'io_uring' для всех дисков."
                    print_rec "Это лучшая настройка для производительности."
                else
                    print_ok "Режим 'Async IO' установлен в 'io_uring' (оптимально)."
                fi

                # Проверка NUMA
                if echo "$FUTURE_CONFIG_JSON" | jq -e '.numa != 1' > /dev/null; then
                    # Проверяем, что есть основания для рекомендации
                    local MEMORY_MB=$(echo "$FUTURE_CONFIG_JSON" | jq -r '.memory')
                    local CORES=$(echo "$FUTURE_CONFIG_JSON" | jq -r '.cores')
                    local SOCKETS=$(echo "$FUTURE_CONFIG_JSON" | jq -r '.sockets')
                    local VCPUS=$((CORES * SOCKETS))
                    if [ "$MEMORY_MB" -gt 16000 ] && [ "$VCPUS" -gt 4 ]; then
                        print_warn "NUMA не включен."
                        print_rec "Для ВМ с >16GB RAM и >4 vCPU включение NUMA может улучшить производительность памяти."
                    fi
                else
                    print_ok "NUMA включен."
                fi

                # Анализ ZFS-хранилища под диском ВМ
                local CHECKED_STORAGES=""
                echo "$ALL_DISK_CONFIGS" | while IFS= read -r disk_line; do
                    if echo "$disk_line" | grep -q 'media=cdrom'; then continue; fi
                    
                    local DISK_KEY=$(echo "$disk_line" | cut -d':' -f1)
                    local DISK_VALUE=$(echo "$disk_line" | cut -d':' -f2-)
                    local STORAGE_NAME=$(echo "$DISK_VALUE" | cut -d':' -f1)

                    # Проверка кэширования для каждого конкретного диска
                    if echo "$DISK_VALUE" | grep -q "cache=writeback"; then
                         print_warn "Диск '$DISK_KEY' использует кэш 'writeback'."
                         print_rec "Это рискованно. Безопасный режим для ZFS - 'writethrough', для LVM/DIR - 'none'."
                         print_rec "Режим 'writeback' рекомендуется использовать ТОЛЬКО для дисков tempdb."
                    fi

                    # Проверка формата диска
                    if echo "$DISK_VALUE" | grep -q ".qcow2"; then
                        print_warn "Диск '$DISK_KEY' использует формат qcow2. Для блочных хранилищ (ZFS/LVM) 'raw' производительнее."
                    fi

                    # Проверяем параметры хранилища только один раз
                    if [[ $CHECKED_STORAGES == *"$STORAGE_NAME"* ]]; then continue; fi
                    CHECKED_STORAGES="$CHECKED_STORAGES $STORAGE_NAME"

                    local STORAGE_CONFIG_JSON=$(pvesh get /storage/"$STORAGE_NAME" --output-format json 2>/dev/null)
                    if [ -z "$STORAGE_CONFIG_JSON" ]; then continue; fi
                    local STORAGE_TYPE=$(echo "$STORAGE_CONFIG_JSON" | jq -r '.type' 2>/dev/null)

                    # Проверки, специфичные для ZFS
                    if [[ "$STORAGE_TYPE" == "zfspool" ]]; then
                        print_debug "Конфигурация ZFS-хранилища '$STORAGE_NAME' (pvesh get):" "$STORAGE_CONFIG_JSON"

                        local ZFS_BLOCKSIZE=$(echo "$STORAGE_CONFIG_JSON" | jq -r '.blocksize // "8k"') 
                        local ZFS_DATASET_NAME=$(echo "$STORAGE_CONFIG_JSON" | jq -r '.pool' 2>/dev/null)
                        local ZFS_SYNC_PROP=$(zfs get -H -o value sync "$ZFS_DATASET_NAME" 2>/dev/null)
                        
                        print_info "Параметры хранилища '$STORAGE_NAME' (датасет $ZFS_DATASET_NAME):"
                        
                        if [ "$ZFS_SYNC_PROP" != "standard" ]; then
                            print_error "    - Свойство 'sync' для датасета '$ZFS_DATASET_NAME' установлено в '$ZFS_SYNC_PROP'! Для БД это ОПАСНО."
                            print_rec "    - Выполните: zfs set sync=standard $ZFS_DATASET_NAME"
                        else
                            print_ok "    - Свойство 'sync' для датасета '$ZFS_DATASET_NAME' установлено в 'standard' (безопасно)."
                        fi
                        
                        ZFS_BLOCKSIZE_UPPER=$(echo "$ZFS_BLOCKSIZE" | tr 'a-z' 'A-Z')
                        if [ "$ZFS_BLOCKSIZE_UPPER" != "8K" ] && [ "$ZFS_BLOCKSIZE_UPPER" != "16K" ]; then
                            print_warn "    - Размер блока 'blocksize' равен '$ZFS_BLOCKSIZE'. Для MS SQL часто рекомендуют 8K или 16K, чтобы соответствовать размеру страниц SQL."
                        else
                            print_ok "    - Размер блока 'blocksize' равен '$ZFS_BLOCKSIZE' (хороший выбор для SQL)."
                        fi
                    fi
                done
            fi
        done
    fi

    # --- Проверка Контейнеров ---
    local CT_LIST=$(pct list | awk 'NR>1 {print $1}')
    if [ -n "$CT_LIST" ]; then
        echo
        print_info "Анализ Контейнеров (LXC)..."
        for CTID in $CT_LIST; do
            local CT_DETAILS=$(pct list | grep " $CTID ")
            local CT_NAME=$(echo "$CT_DETAILS" | awk '{print $4}')
            [ -z "$CT_NAME" ] && CT_NAME="unknown"
            
            echo
            print_info "Анализ КТ ${CTID} (${CT_NAME})"

            # Проверка на непривилегированность
            if pct config $CTID | grep -q 'unprivileged: 1'; then
                print_ok "Контейнер непривилегированный (хорошая практика безопасности)."
            else
                print_warn "Контейнер привилегированный. Это менее безопасно."
                print_rec "Создавайте новые контейнеры как непривилегированные, если нет особых требований."
            fi
        done
    else
        print_info "Контейнеры не найдены."
    fi
}

# --- 14. Проверка статуса IOMMU ---
check_iommu() {
    print_header "14. Проверка статуса IOMMU (для PCI Passthrough)"
    if dmesg | grep -q -e "DMAR: IOMMU enabled" -e "AMD-Vi: IOMMU performance counters supported"; then
        print_ok "IOMMU (Intel VT-d / AMD-Vi) включен в ядре."
        print_info "Это позволяет пробрасывать PCI-устройства в виртуальные машины."
    else
        print_info "IOMMU не обнаружен в логах загрузки ядра."
        print_rec "Если вам нужен PCI Passthrough, убедитесь, что Intel VT-d или AMD-Vi включены в BIOS/UEFI,"
        print_rec "и добавьте 'intel_iommu=on' или 'amd_iommu=on' в параметры загрузки ядра."
    fi
}

# --- 15. Анализ системного журнала ---
check_system_logs() {
    print_header "15. Анализ системного журнала (за последние 24 часа)"
    # Ищем сообщения с высоким приоритетом (от emergency до error)
    # 0=emerg, 1=alert, 2=crit, 3=err
    # Получаем логи, убираем служебные строки journalctl
    CLEAN_LOGS=$(journalctl --since "24 hours ago" -p 0..3 --no-pager | grep -v -e '^--' -e 'systemd-journald' -e 'systemd\[' )

    if [ -n "$CLEAN_LOGS" ]; then
        # Считаем только непустые строки
        LOG_COUNT=$(echo "$CLEAN_LOGS" | grep -c .)
        
        if [ "$LOG_COUNT" -gt 0 ]; then
            print_error "В системном журнале за последние 24 часа обнаружено ${LOG_COUNT} сообщений с высоким приоритетом!"
            print_rec "Рекомендуется изучить их. Пример команды для просмотра: journalctl -p 3 -b"
            echo -e "${C_CYAN}    └── Последние 5 сообщений:${C_RESET}"
            # Выводим последние 5 строк из отфильтрованного лога
            echo "$CLEAN_LOGS" | tail -n 5 | sed 's/^/        /'
        else
            print_ok "В системном журнале за последние 24 часа не найдено критических ошибок."
        fi
    else
        print_ok "В системном журнале за последние 24 часа не найдено критических ошибок."
    fi
}

# --- 16. Анализ дискового пространства для логов ---
check_log_usage() {
    print_header "16. Анализ использования диска логами"
    LOG_DIR="/var/log"
    LOG_USAGE_GB=$(du -sh "$LOG_DIR" 2>/dev/null | awk '{print $1}')
    
    if [ -n "$LOG_USAGE_GB" ]; then
        print_info "Директория логов ($LOG_DIR) занимает: $LOG_USAGE_GB"
        # Попробуем извлечь числовое значение для сравнения
        SIZE_VALUE=$(echo "$LOG_USAGE_GB" | sed 's/[^0-9.]*//g')
        SIZE_UNIT=$(echo "$LOG_USAGE_GB" | sed 's/[0-9.]*//g')
        
        # Проверяем, если размер в гигабайтах и больше 5
        if [[ "$SIZE_UNIT" == "G" && $(echo "$SIZE_VALUE > 5" | bc -l) -eq 1 ]]; then
            print_warn "Директория логов занимает более 5 ГБ! Это может быть признаком проблемы или отсутствия ротации."
            print_rec "Проверьте самые большие файлы с помощью 'du -ah /var/log | sort -rh | head -n 10'."
            print_rec "Настройте лимит для journald в /etc/systemd/journald.conf (например, SystemMaxUse=500M)."
        else
            print_ok "Размер директории логов в пределах нормы."
        fi
    fi
}

# --- 17. Проверка настройки Swappiness ---
check_swappiness() {
    print_header "17. Проверка настройки Swappiness"
    SWAPPINESS=$(cat /proc/sys/vm/swappiness)
    print_info "Текущее значение vm.swappiness: $SWAPPINESS"
    
    if [ "$SWAPPINESS" -gt 10 ]; then
        print_warn "Значение swappiness ($SWAPPINESS) выше рекомендуемого (10). Система может начать использовать SWAP слишком рано."
        print_rec "Рекомендуется установить низкое значение. Пример: sysctl -w vm.swappiness=10"
        print_rec "Для сохранения после перезагрузки: echo 'vm.swappiness=10' >> /etc/sysctl.conf"
    else
        print_ok "Значение swappiness ($SWAPPINESS) оптимально (<= 10)."
    fi
}

# --- 18. Проверка системных лимитов ---
check_system_limits() {
    print_header "18. Проверка системных лимитов (открытые файлы и процессы)"
    
    # Открытые файлы
    local CURRENT_OPEN_FILES=$(cat /proc/sys/fs/file-nr | awk '{print $1}')
    local MAX_OPEN_FILES=$(cat /proc/sys/fs/file-max)
    
    print_info "Открытые файлы (всего в системе): $CURRENT_OPEN_FILES (системный лимит: $MAX_OPEN_FILES)"

    local FILE_THRESHOLD=100000 
    if [ "$CURRENT_OPEN_FILES" -gt "$FILE_THRESHOLD" ]; then
        print_warn "Количество открытых файлов в системе ($CURRENT_OPEN_FILES) велико. (больше $FILE_THRESHOLD)"
        print_rec "Это может указывать на утечку файловых дескрипторов. Проверьте с помощью 'lsof'."
    else
        print_ok "Количество открытых файлов в системе в пределах разумного."
    fi

    # Процессы (PID)
    local CURRENT_PIDS=$(ps -e --no-headers | wc -l)
    local MAX_PIDS=$(cat /proc/sys/kernel/pid_max)
    local PID_USAGE_PERCENT=$((CURRENT_PIDS * 100 / MAX_PIDS))

    print_info "Запущенные процессы (PID): $CURRENT_PIDS из $MAX_PIDS (${PID_USAGE_PERCENT}%)"
     if [ "$PID_USAGE_PERCENT" -gt 80 ]; then
        print_warn "Количество процессов превысило 80% от лимита."
        print_rec "Рассмотрите возможность увеличения лимита в /etc/sysctl.conf (kernel.pid_max)."
    else
        print_ok "Количество процессов в норме."
    fi
}

# --- 19. Проверка на наличие зомби-процессов ---
check_zombie_processes() {
    print_header "19. Проверка на наличие зомби-процессов"
    # Ищем процессы в состоянии 'Z' (zombie)
    ZOMBIE_COUNT=$(ps -A -o stat | grep -c '^Z')
    
    if [ "$ZOMBIE_COUNT" -gt 0 ]; then
        print_error "Обнаружено ${ZOMBIE_COUNT} зомби-процессов! Это указывает на проблему с одним из приложений."
        print_rec "Найдите их с помощью команды 'ps aux | grep Z' и определите родительский процесс."
    else
        print_ok "Зомби-процессы не обнаружены."
    fi
}

# ==============================================================================
#                                ГЛАВНАЯ ФУНКЦИЯ
# ==============================================================================

# --- Справка ---
print_help() {
    echo "PVE-Checkup: Скрипт для аудита и выдачи рекомендаций по Proxmox VE."
    echo
    echo "Использование: $0 [ОПЦИИ]"
    echo
    echo "Опции:"
    echo "  --db-vms <VM_IDS>       Провести углубленный анализ как для сервера БД только для ВМ"
    echo "                          с указанными ID (через запятую, без пробелов)."
    echo "                          Отключает интерактивные запросы по этому поводу."
    echo "                          Пример: $0 --db-vms 101,105"
    echo
    echo "  --skip-db-details       Полностью пропустить углубленный анализ ВМ как для"
    echo "                          серверов БД. Игнорируется, если указана опция --db-vms."
    echo
    echo "  --debug                 Включить отладочный режим. Выводит 'сырые' данные, на основе"
    echo "                          которых делаются выводы."
    echo
    echo "  -h, --help              Показать это справочное сообщение и выйти."
    echo
    echo "По умолчанию (без опций --db-vms или --skip-db-details) скрипт будет"
    echo "запрашивать подтверждение для углубленного анализа каждой ВМ."
}

main() {
    # --- Парсинг аргументов командной строки ---
    DB_VMS_ARG=""
    SKIP_DB_DETAILS_FLAG=0
    # Используем цикл для обработки нескольких возможных флагов в будущем
    while [[ $# -gt 0 ]]; do
        key="$1"
        case $key in
            -h|--help)
            print_help
            exit 0
            ;;
            --db-vms)
            if [[ -n "$2" && ! "$2" =~ ^-- ]]; then
                DB_VMS_ARG="$2"
                shift # съедаем значение аргумента
            else
                echo -e "${C_RED}Ошибка: для опции --db-vms требуется значение (список ID ВМ).${C_RESET}" >&2
                exit 1
            fi
            ;;
            --skip-db-details)
            SKIP_DB_DETAILS_FLAG=1
            ;;
            --debug)
            DEBUG_MODE=1
            ;;
            *)
            # Неизвестная опция
            echo -e "${C_RED}Неизвестная опция: $1${C_RESET}" >&2
            print_help
            exit 1
            ;;
        esac
        shift # съедаем ключ (--db-vms, -h, etc.)
    done

    clear
    echo -e "${C_WHITE}Запуск аудита системы Proxmox VE...${C_RESET}"
    
    check_dependencies
    check_pve_system
    check_zfs_arc
    check_zfs_pools_deep
    check_pve_specifics
    check_performance
    check_network
    check_security
    check_vm_disks
    check_host_backup
    check_ntp_sync
    check_kernel_reboot
    check_qemu_agent
    
    # Передаем список ВМ в функцию
    check_vm_ct_tuning "$DB_VMS_ARG" "$SKIP_DB_DETAILS_FLAG"

    check_iommu
    check_system_logs
    check_log_usage
    check_swappiness
    check_system_limits
    check_zombie_processes

    echo -e "\n${C_GREEN}Аудит завершен.${C_RESET}\n"
}

main "$@"