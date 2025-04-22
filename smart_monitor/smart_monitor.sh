#!/bin/bash

# --- Загрузка конфига ---
CONFIG_FILE="./smart_monitor.conf"
if [ -f "$CONFIG_FILE" ]; then
    . "$CONFIG_FILE"
else
    echo "Config file $CONFIG_FILE not found!" >&2
    exit 1
fi

# --- Load library ---
LIBRARY_FILE_COMMON="./lib_common.sh"
if [ -f "$LIBRARY_FILE_COMMON" ]; then
    . "$LIBRARY_FILE_COMMON"
else
    echo "Library file $LIBRARY_FILE_COMMON not found!" >&2
    exit 1
fi

LIBRARY_FILE_SMART="./smart_lib.sh"
if [ -f "$LIBRARY_FILE_SMART" ]; then
    . "$LIBRARY_FILE_SMART"
else
    echo "Library file $LIBRARY_FILE_SMART not found!" >&2
    exit 1
fi


# --- Настройки ---
LOG="${LOG_SMART_CHECK:-/var/log/smart_check.log}"
START_TIME=$(date "+%Y-%m-%d %H:%M:%S")

{
    echo "=========================================="
    echo "Smart check started at $START_TIME" 
    echo ""
    echo "Config loaded from: $CONFIG_FILE"
    echo ""
    echo "--- Disk Check Results ---"
} >> "$LOG"

# --- Поиск дисков (исключаем виртуальные устройства) ---
DISKS_HDD=$(lsblk -d -o NAME,ROTA,TYPE | awk '$2 == "1" && $3 == "disk" && $1 !~ /^loop|^sr/ {print "/dev/"$1}')
DISKS_NVME=$(lsblk -d -o NAME,TYPE | awk '$1 ~ /^nvme/ && $2 == "disk" {print "/dev/"$1}')
DISKS_SSD=$(comm -23 \
    <(lsblk -d -o NAME,ROTA,TYPE | awk '$2 == "0" && $3 == "disk" && $1 !~ /^loop|^nvme|^sr/ {print "/dev/"$1}' | sort) \
    <(echo "$DISKS_NVME" | sort))

# --- Проверка диска ---
check_disk() {
    local disk=$1
    local disk_type=$2
    local -A result=(
        ["disk"]="$disk"
        ["type"]="$disk_type"
        ["status"]="UNKNOWN"
        ["errors"]=""
        ["wearout"]=""
        ["written_gb"]=""
    )

    local smartctl_full=$(sudo smartctl --all "$disk" 2>/dev/null)

    # Проверяем на не поддерживаемые устройства
    if echo "$smartctl_full" | grep -q "Unknown USB bridge"; then
        echo "[$(date '+%H:%M:%S')] Пропускаем не поддерживаемое устройство: $disk (Unknown USB bridge)" >> "$LOG"
        result["status"]="SKIPPED_UNSUPPORTED"
        echo "$(declare -p result)"
        return 0
    fi

    # Проверяем доступность SMART данных
    if ! echo "$smartctl_full" | grep -q "SMART support is: Available"; then
        echo "[$(date '+%H:%M:%S')] Пропускаем устройство без SMART: $disk" >> "$LOG"
        result["status"]="SKIPPED_NO_SMART"
        echo "$(declare -p result)"
        return 0
    fi

    local smartctl_health=$(sudo smartctl --health "$disk" 2>/dev/null)
    local smartctl_attributes=$(sudo smartctl --attributes "$disk" 2>/dev/null)

    result["sector_size"]=$(get_sector_size "$disk" "$smartctl_full")

    # Для NVMe используем отдельную логику
    if [[ "$disk_type" == "NVMe" ]]; then
        if [[ "$SHOW_SSD_WRITTEN" == "1" ]]; then
            result["written_gb"]=$(get_nvme_written "$disk_type" "${result["sector_size"]}" "$smartctl_full")
        fi

        if [[ "$SHOW_SSD_WEAROUT" == "1" ]]; then
            result["wearout"]=$(get_nvme_wearout "$smartctl_full")
        fi
    fi

    # Для SATA SSD
    if [[ "$disk_type" == "SATA SSD" ]]; then
        if [[ "$SHOW_SSD_WRITTEN" == "1" ]]; then
            result["written_gb"]=$(get_ssd_written "$disk" "$smartctl_full" "${result["sector_size"]}" "$smartctl_full")
        fi

        if [[ "$SHOW_SSD_WEAROUT" == "1" ]]; then
            result["wearout"]=$(get_ssd_wearout "$smartctl_full")
        fi
    fi

    # Проверка здоровья диска (основная проверка SMART)
    if [[ "$disk_type" == "NVMe" ]]; then
        result["status"]=$(echo "$smartctl_health" | grep -i "SMART overall-health" | awk '{print $NF}')
    else
        result["status"]=$(echo "$smartctl_health" | grep -i "test result" | awk '{print $NF}')
    fi

    # Сбор ошибок (для HDD и SSD)

    if [[ "$disk_type" != "NVMe" ]]; then
        result["errors"]=$(echo "$smartctl_attributes" | grep -E "Reallocated_Sector_Ct|Current_Pending_Sector|Uncorrectable_Error_Ct" | awk '$10 != "0" {print $2, $10}')
    fi

    echo "$(declare -p result)"
}

# --- Основная проверка ---
declare -a ALL_RESULTS
ERRORS_FOUND=0

{
    echo "--- Проверка дисков ---"
    echo "Типы дисков:"
    echo "HDD: $DISKS_HDD"
    echo "SATA SSD: $DISKS_SSD"
    echo "NVMe: $DISKS_NVME"
    echo ""
} >> "$LOG"

for disk in $DISKS_HDD $DISKS_SSD $DISKS_NVME; do
    if [[ "$DISKS_HDD" == *"$disk"* ]]; then
        disk_type="HDD"
    elif [[ "$DISKS_SSD" == *"$disk"* ]]; then
        disk_type="SATA SSD"
    else
        disk_type="NVMe"
    fi

    disk_result=$(check_disk "$disk" "$disk_type")
    eval "$disk_result"

    # Пропускаем не поддерживаемые диски
    if [[ "${result[status]}" == "SKIPPED_UNSUPPORTED" || "${result[status]}" == "SKIPPED_NO_SMART" ]]; then
        continue
    fi
    
    # Человеко-читаемый лог
    {
        printf "Диск: %-16s | Тип: %-8s | Статус: %-6s" "${result[disk]}" "${result[type]}" "${result[status]}"
        [ -n "${result[errors]}" ] && printf " | Ошибки: %s" "${result[errors]}"
        printf "\n"
    } >> "$LOG"
    
    ALL_RESULTS+=("$(declare -p result)")
    [[ "${result[status]}" != "PASSED" ]] && ERRORS_FOUND=1
done

# --- Уведомление в Telegram ---
TELEGRAM_STATUS="Not sent"
if [[ "$TELEGRAM_POST_MESSAGE_ALWAYS" == "1" || "$ERRORS_FOUND" == "1" ]]; then
    # Формируем сообщение с HTML-разметкой
    MESSAGE="<b>🛡️ SMART Report</b> | $(date '+%Y-%m-%d %H:%M:%S')%0A%0A"
    MESSAGE+="<b>Host</b>: $(hostname)%0A%0A"

    for result_str in "${ALL_RESULTS[@]}"; do
        eval "$result_str"

        if [[ "${result[status]}" == "PASSED" ]]; then
            MESSAGE+="✅ <b>${result[type]}</b>: <code>${result[disk]}</code> (PASSED)%0A"
            [[ -n "${result[wearout]}" ]] && MESSAGE+=" Износ: <code>${result[wearout]}%</code>%0A"
            [[ -n "${result[written_gb]}" ]] && MESSAGE+=" %0AЗаписано: <code>${result[written_gb]} GB</code>"
            MESSAGE+="%0A%0A"
        else
            MESSAGE+="🔴 <b>${result[type]}</b>: <code>${result[disk]}</code> (${result[status]})%0A"

            [[ -n "${result[wearout]}" ]] && MESSAGE+="Износ: <code>${result[wearout]}%</code>%0A"
            [[ -n "${result[written_gb]}" ]] && MESSAGE+="Записано: <code>${result[written_gb]} GB</code>%0A"
            [[ -n "${result[errors]}" ]] && MESSAGE+="<b>Errors</b>: <code>${result[errors]// /</code> <code>}</code>%0A"
            MESSAGE+="%0A"
        fi
    done

    # Отправляем в Telegram
    TELEGRAM_STATUS=$(send_to_telegram "$TELEGRAM_BOT_TOKEN" "$TELEGRAM_CHAT_ID" "$MESSAGE")
fi

# --- Финальный лог ---
{
    echo ""
    echo "--- Notification Status ---"
    echo "Telegram: $TELEGRAM_STATUS"
    echo ""
    echo "Finished at: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "=========================================="
    echo ""
} >> "$LOG"

