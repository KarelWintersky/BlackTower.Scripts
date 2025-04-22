#!/bin/bash

#
# --- Посылает в телегу сообщение
#
send_to_telegram() {
    local bot_token="$1"
    local chat_id="$2"
    local message="$3"
    local attempt=0
    local max_attempts=3
    local timeout=2
    local result="Failed"

    while [ $attempt -lt $max_attempts ]; do
        if curl -s --max-time $timeout -X POST \
           "https://api.telegram.org/bot${bot_token}/sendMessage" \
           -d "chat_id=${chat_id}" \
           -d "text=${message}" \
           -d "parse_mode=HTML" >/dev/null 2>&1; then
            result="Success"
            break
        fi
        attempt=$((attempt + 1))
        sleep $timeout
    done

    echo "$result"
}

#
# Очищает строку с числом от незначимых символов (точки, запятые, пробелы всех видов)
#
clean_number() {
    local num="$1"
    # Удаляем: обычные пробелы, неразрывные пробелы (U+00A0 и U+202F), запятые
    echo "$num" |
    tr -d ',' |
    tr -d ' ' |
    tr -d $'\u00A0' |
    sed 's/\xc2\xa0//g' |
    sed 's/\xe2\x80\xaf//g' |
    sed  -e 's/ //g'
}

#
# Выясняет количество записанных на SSD гигабайт
#
get_ssd_written() {
    local disk="$1"
    local sector_size="$2"
    local smart_data=$(sudo smartctl -A "$disk" 2>/dev/null)

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

    log_immediately ${result}
    echo ${result}
}

#
# Немедленно печатает на экран сообщение
#
log_immediately() {
    local message="$1"
    echo "$(date '+%H:%M:%S') - $message" > /dev/tty
}

get_sector_size() {
    local disk="$1"
    local smartctl_output="${2:-}"

    # Если вывод smartctl не передан, получаем его
    [[ -z "$smartctl_output" ]] && smartctl_output=$(sudo smartctl --all "$disk" 2>/dev/null)

    # Пробуем разные варианты определения размера сектора
    local sector_size=$(echo "$smartctl_output" | awk '
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




