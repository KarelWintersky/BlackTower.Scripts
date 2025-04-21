#!/bin/bash

# --- Telegram sender function ---
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

