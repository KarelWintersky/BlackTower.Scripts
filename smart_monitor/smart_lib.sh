#!/bin/bash

check_smart_available() {
    local disk="$1"
    local disk_type="$2"
    local smart_data="$3"

    if [[ "$disk_type" == "NVMe" ]]; then
        # Для NVMe проверяем наличие строки SMART overall-health
        if echo "$smart_data" | grep -q "SMART overall-health"; then
            return 0
        else
            echo "[$(date '+%H:%M:%S')] NVMe диск не поддерживает SMART: $disk" >> "$LOG"
            return 1
        fi
    else
        # Для SATA/HDD проверяем стандартную строку
        if echo "$smart_data" | grep -q "SMART support is: Available"; then
            return 0
        else
            echo "[$(date '+%H:%M:%S')] Диск без поддержки SMART: $disk" >> "$LOG"
            return 1
        fi
    fi
}

#
# Вычисляет размер сектора на диске
# 1: /dev/xxx
# 2: smartctl --all
#
get_sector_size() {
    local disk="$1"
    local smart_data="${2:-}"

    # Если вывод smartctl не передан, получаем его
    [[ -z "$smart_data" ]] && smart_data=$(sudo smartctl --all "$disk" 2>/dev/null)

    if echo "$smart_data" | grep -q "Unknown USB bridge"; then
        echo "0"
        return 1
    fi

    # Пробуем разные варианты определения размера сектора
    local sector_size=$(echo "$smart_data" | awk '
        /Sector Size:/ {print $4}
        /Sectors? size:/ {print $NF}
        /Logical block size:/ {print $NF}
    ' | head -1)

    # Проверяем корректность значения
    if [[ ! "$sector_size" =~ ^[0-9]+$ ]] || (( sector_size < 512 )) || (( sector_size > 4096 )); then
        sector_size="512"
    fi

    echo "$sector_size"
}

#
# Выясняет количество записанных на SSD гигабайт
# 1: disk (/dev/xxx)
# 2: smartctl --all
# 3: sector size
#
get_ssd_written() {
    local disk="$1"
    local smart_data="${2:-}"
    local sector_size="$3"

    # Если вывод smartctl не передан, получаем его
    [[ -z "$smart_data" ]] && smart_data=$(sudo smartctl --all "$disk" 2>/dev/null)

    # Пробуем разные варианты атрибутов
    local raw_value=$(echo "$smart_data" | awk '/Total_LBAs_Written/{print $10}')
    [[ -z "$raw_value" ]] && raw_value=$(echo "$smart_data" | awk '/241 Total_LBAs_Written/{print $10}')

    # Очищаем значение (удаляем все нецифровые символы)
    local sectors_written=$(clean_number "$raw_value")

    local result=0

    if [[ -n "$sectors_written" && "$sectors_written" =~ ^[0-9]+$ ]]; then
        result=$(echo "scale=2; $sectors_written * $sector_size / 1073741824" | bc)
    else
        result="N/A"
    fi

    echo ${result}
}

#
# Выясняет количество записанных на NVME гигабайт
# 1: disk (/dev/xxx)
# 2: sector size
# 3: smartctl --all
#
get_nvme_written() {
    local disk="$1"
    local sector_size="$2"
    local smart_data="${3:-}"

    # Если вывод smartctl не передан, получаем его
    [[ -z "$smart_data" ]] && smart_data=$(sudo smartctl --all "$disk" 2>/dev/null)

    # Пробуем разные варианты атрибутов
    local raw_data=$(echo "$smart_data" | grep "Data Units Written" | awk '{print $4}')

    local sectors_written=$(clean_number "$raw_data")

    if [[ -n "$sectors_written" && "$sectors_written" =~ ^[0-9]+$ ]]; then
        result=$(echo "scale=2; $sectors_written * 1000 * $sector_size / 1073741824" | bc)
    else
        result="N/A"
    fi

    echo $result
}

#
# Вычисляем износ NVME
# 1: smartctl --all
#
get_nvme_wearout() {
    local smart_data="$1"

    # Получаем сырое значение из разных возможных атрибутов
    local raw_value=$(echo "$smart_data" | awk '
        /Percentage Used:/ {sub(/%/, "", $3); print $3}
        /percent lifetime remaining:/ {print 100 - $NF}
        /Wear Leveling Count:/ {print $4}
        /Wear_Leveling_Count/ {print $NF}
    ' | head -1)

    # Очищаем от возможных нецифровых символов
    # local cleaned=$(echo "$raw_value" | tr -d '% ' | sed 's/[^0-9]//g')
    local cleaned=$(echo "$raw_value" | sed -E 's/[^0-9]//g; s/^0+([0-9])/\1/')

    # Проверяем валидность
    if [[ -z "$cleaned" ]]; then
        echo "N/A"
        return 1
    fi

    if (( cleaned >= 0 && cleaned <= 100 )); then
        echo "$cleaned"
    else
        echo "N/A"
        return 1
    fi
}

#
# Вычисляем износ SSD
# 1: smartctl --all
#
get_ssd_wearout_() {
    local smart_data="$1"
    local wearout="N/A"

    # Пробуем получить Percent_Lifetime_Remain (обратный расчет: 100 - значение)
    local raw_value=$(echo "$smart_data" | awk '/Percent_Lifetime_Remain/{print $4}')
    local lifetime_remain=$(echo "$raw_value" | sed -E 's/[^0-9]//g; s/^0+([0-9])/\1/')

    if [[ -n "$lifetime_remain" && "$lifetime_remain" =~ ^[0-9]+$ ]]; then
        wearout=$((100 - lifetime_remain))
    else
        # Если не нашли, пробуем Wear_Leveling_Count
        local wlc=$(echo "$smart_data" | awk '/Wear_Leveling_Count/{print $4}')
        [[ -n "$wlc" && "$wlc" =~ ^[0-9]+$ ]] && wearout="$wlc"
    fi

    # Проверяем валидность результата (0-100)
    if [[ "$wearout" =~ ^[0-9]+$ ]] && (( wearout >= 0 && wearout <= 100 )); then
        echo "$wearout"
    else
        echo "N/A"
        return 1
    fi
}

get_ssd_wearout() {
    local smart_data="$1"

    # Пробуем получить Percent_Lifetime_Remain
    local raw_value=$(echo "$smart_data" | awk '/Percent_Lifetime_Remain/{print $4}')
    lifetime_remain=$(echo "$raw_value" | sed -E 's/[^0-9]//g; s/^0+([0-9])/\1/')

    if [[ -n "$lifetime_remain" && "$lifetime_remain" =~ ^[0-9]+$ ]]; then
        local wearout=$((100 - $lifetime_remain))
        log_immediately "$wearout"
        (( wearout >= 0 && wearout <= 100 )) && echo "$wearout" && return 0
    fi

    # Пробуем получить Wear_Leveling_Count
    raw_value=$(echo "$smart_data" | awk '/Wear_Leveling_Count/{print $4}')
    wlc=$(echo "$raw_value" | sed -E 's/[^0-9]//g; s/^0+([0-9])/\1/')
    if [[ -n "$wlc" && "$wlc" =~ ^0*[0-9]+$ ]]; then
        wlc=$((100 - $wlc))
        (( 10#$wlc >= 0 && 10#$wlc <= 100 )) && echo "$((10#$wlc))" && return 0
    fi

    echo "N/A"
    return 1
}