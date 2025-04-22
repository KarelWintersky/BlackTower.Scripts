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
# Немедленно печатает на экран сообщение
#
log_immediately() {
    local message="$1"
    echo "$(date '+%H:%M:%S') - $message" > /dev/tty
}






