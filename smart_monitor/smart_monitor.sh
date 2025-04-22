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
LIBRARY_FILE="./lib_common.sh"
if [ -f "$LIBRARY_FILE" ]; then
    . "$LIBRARY_FILE"
else
    echo "Library file $LIBRARY_FILE not found!" >&2
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

    result["sector_size"]=$(get_sector_size "$disk" "$smartctl_full")

    # Для NVMe используем отдельную логику
    if [[ "$disk_type" == "NVMe" ]]; then
        if [[ "$SHOW_SSD_WRITTEN" == "1" ]]; then
            local raw_data=$(echo "$smartctl_full" | grep "Data Units Written" | awk '{print $4}')
            local data_units=$(clean_number "$raw_data")

            if [[ -n "$data_units" && "$data_units" =~ ^[0-9]+$ ]]; then
              # 1 Data Unit = 1000 sectors (по спецификации NVMe)
                local bytes_written=$((data_units * 1000 * ${result["sector_size"]}))
                result["written_gb"]=$(echo "scale=2; $bytes_written/1073741824" | bc)
            fi
        fi

        if [[ "$SHOW_SSD_WEAROUT" == "1" ]]; then
            result["wearout"]=$(echo "$smartctl_full" | grep "Percentage Used" | awk '{print $3}' | tr -d '%')
        fi
    fi

    # Для SATA SSD
    if [[ "$disk_type" == "SATA SSD" ]]; then
        if [[ "$SHOW_SSD_WRITTEN" == "1" ]]; then
            result["written_gb"]=$(get_ssd_written "$disk" "${result["sector_size"]}")
        fi

        if [[ "$SHOW_SSD_WEAROUT" == "1" ]]; then
            result["wearout"]=$(echo "$smartctl_full" | grep "Percent_Lifetime_Remain" | awk '{print 100 - $4}')
            [[ -z "${result["wearout"]}" ]] && result["wearout"]=$(echo "$smartctl_full" | grep "Wear_Leveling_Count" | awk '{print $4}')
        fi
    fi

    # Проверка здоровья диска (основная проверка SMART)
    local smart_health=$(sudo smartctl -H "$disk" 2>/dev/null)
    if [[ "$disk_type" == "NVMe" ]]; then
        result["status"]=$(echo "$smart_health" | grep -i "SMART overall-health" | awk '{print $NF}')
    else
        result["status"]=$(echo "$smart_health" | grep -i "test result" | awk '{print $NF}')
    fi

    # Сбор ошибок (для HDD и SSD)
    local smart_errors=$(sudo smartctl -A "$disk" 2>/dev/null)
    if [[ "$disk_type" != "NVMe" ]]; then
        result["errors"]=$(echo "$smart_errors" | grep -E "Reallocated_Sector_Ct|Current_Pending_Sector|Uncorrectable_Error_Ct" | awk '$10 != "0" {print $2, $10}')
    fi

    echo "$(declare -p result)"
}

# --- Основная проверка ---
declare -a ALL_RESULTS
ERRORS_FOUND=0

#{
#    echo "--- Проверка дисков ---"
#    echo "Типы дисков:"
#    echo "HDD: $DISKS_HDD"
#    echo "SATA SSD: $DISKS_SSD"
#    echo "NVMe: $DISKS_NVME"
#    echo ""
#} >> "$LOG"

for disk in $DISKS_HDD $DISKS_SSD $DISKS_NVME; do
    if [[ "$DISKS_HDD" == *"$disk"* ]]; then
        disk_type="HDD"
    elif [[ "$DISKS_SSD" == *"$disk"* ]]; then
        disk_type="SATA SSD"
    else
        disk_type="NVMe"
    fi
    
    eval "$(check_disk "$disk" "$disk_type")"
    
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

