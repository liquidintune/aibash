#!/bin/bash

set -e
LOG_FILE="/var/log/monitoring_script.log"
CONFIG_FILE="$HOME/.telegram_bot_config"
SECRET_FILE="$HOME/.telegram_bot_secret"
STATUS_FILE="/tmp/monitoring_status"
VM_STATUS_FILE="/tmp/vm_monitoring_status"

# Функция для логирования
log() {
    local message="$1"
    echo "$(date +'%Y-%m-%d %H:%M:%S') - $message" >> "$LOG_FILE"
}

# Функция для установки необходимых пакетов
install_packages() {
    if [[ -f /etc/debian_version ]]; then
        log "Debian-based OS detected"
        if ! command -v jq &> /dev/null; then
            apt-get update && apt-get install -y jq curl
            log "Installed jq and curl"
        fi
    elif [[ -f /etc/redhat-release ]]; then
        log "RedHat-based OS detected"
        if ! command -v jq &> /dev/null; then
            yum install -y epel-release && yum install -y jq curl
            log "Installed jq and curl"
        fi
    else
        log "Unsupported OS"
        echo "Unsupported OS"
        exit 1
    fi
}

# Функция для определения типа сервера
determine_server_type() {
    if dpkg -l | grep -q pve-manager; then
        echo "Proxmox"
    else
        echo "LNMP"
    fi
}

# Установка пакетов
install_packages

# Определение типа сервера
SERVER_TYPE=$(determine_server_type)
DEFAULT_SERVICES_TO_MONITOR=""

if [ "$SERVER_TYPE" == "Proxmox" ]; then
    DEFAULT_SERVICES_TO_MONITOR="pve-cluster,pvedaemon,qemu-server,pveproxy"
else
    DEFAULT_SERVICES_TO_MONITOR="nginx,mysql,php7.4-fpm"
fi

# Настройка конфигурации Telegram
configure_telegram() {
    if [ ! -f "$CONFIG_FILE" ]; then
        read -p "Enter Telegram bot token: " TELEGRAM_BOT_TOKEN
        read -p "Enter Telegram group chat ID: " TELEGRAM_CHAT_ID
        read -p "Enter unique server ID: " SERVER_ID
        
        echo "TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN" > "$SECRET_FILE"
        chmod 600 "$SECRET_FILE"
        
        echo "TELEGRAM_CHAT_ID=$TELEGRAM_CHAT_ID" > "$CONFIG_FILE"
        echo "SERVER_ID=$SERVER_ID" >> "$CONFIG_FILE"
        echo "SERVICES_TO_MONITOR=$DEFAULT_SERVICES_TO_MONITOR" >> "$CONFIG_FILE"
        
        log "Configured Telegram bot and saved to $CONFIG_FILE and $SECRET_FILE"
    else
        source "$CONFIG_FILE"
        source "$SECRET_FILE"
    fi
}

# Настройка конфигурации
configure_telegram

# Функция для отправки сообщений в Telegram с обработкой ошибок
send_telegram_message() {
    local message="$1"
    local api_url="https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage"
    local max_length=4096

    # Функция для отправки HTTP запроса
    send_request() {
        local text="$1"
        local data
        data=$(jq -n --arg chat_id "$TELEGRAM_CHAT_ID" --arg text "$text" '{chat_id: $chat_id, text: $text}')
        curl -s -X POST "$api_url" -H "Content-Type: application/json" -d "$data"
    }

    # Разбиваем сообщение на части, если оно слишком длинное
    if [ ${#message} -gt $max_length ]; then
        local parts=()
        while [ ${#message} -gt $max_length ]; do
            parts+=("${message:0:$max_length}")
            message="${message:$max_length}"
        done
        parts+=("$message")

        for part in "${parts[@]}"]; do
            local response=$(send_request "$part")
            log "Sent part of a long message to Telegram"
            handle_response "$response"
        done
    else
        local response=$(send_request "$message")
        log "Sent message to Telegram: $message"
        handle_response "$response"
    fi
}

# Функция для обработки ответа от Telegram API
handle_response() {
    local response="$1"
    local ok=$(echo "$response" | jq -r '.ok')
    if [ "$ok" != "true" ]; then
        local error_code=$(echo "$response" | jq -r '.error_code')
        if [ "$error_code" == "429" ]; then
            local retry_after=$(echo "$response" | jq -r '.parameters.retry_after')
            log "Received Too Many Requests error. Retrying after $retry_after seconds."
            sleep "$retry_after"
            send_telegram_message "$message"
        else
            log "Error sending message: $response"
        fi
    fi
}

# Функция для мониторинга сервисов systemd
monitor_services() {
    local services=($(echo $SERVICES_TO_MONITOR | tr ',' ' '))
    local status_changed=false
    local current_status=""

    for service in "${services[@]}"; do
        if systemctl is-active --quiet "$service"; then
            current_status+="$service:active;"
        else
            current_status+="$service:inactive;"
        fi
    done

    if [ -f "$STATUS_FILE" ]; then
        local previous_status=$(cat "$STATUS_FILE")
        if [ "$current_status" != "$previous_status" ]; then
            status_changed=true
        fi
    else
        status_changed=true
    fi

    if $status_changed; then
        echo "$current_status" > "$STATUS_FILE"
        for service in "${services[@]}"; do
            if ! systemctl is-active --quiet "$service"; then
                send_telegram_message "Service $service is not running on server $SERVER_ID!"
            fi
        done
    fi
}

# Функция для мониторинга виртуальных машин (только для Proxmox)
monitor_vms() {
    if [ "$SERVER_TYPE" == "Proxmox" ]; then
        local vms=$(qm list | awk 'NR>1 {print $1, $2, $3}')
        local status_changed=false
        local current_status=""

        while read -r vm; do
            local vm_id=$(echo "$vm" | awk '{print $1}')
            local vm_name=$(echo "$vm" | awk '{print $2}')
            local status=$(echo "$vm" | awk '{print $3}')
            current_status+="$vm_id:$status;"

            if [ -f "$VM_STATUS_FILE" ]; then
                local previous_status=$(cat "$VM_STATUS_FILE")
                if [[ ! "$previous_status" =~ "$vm_id:$status;" ]]; then
                    status_changed=true
                fi
            else
                status_changed=true
            fi
        done <<< "$vms"

        if $status_changed; then
            echo "$current_status" > "$VM_STATUS_FILE"
            while read -r vm; do
                local vm_id=$(echo "$vm" | awk '{print $1}')
                local vm_name=$(echo "$vm" | awk '{print $2}')
                local status=$(echo "$vm" | awk '{print $3}')

                if [ "$status" != "running" ]; then
                    send_telegram_message "VM $vm is not running on server $SERVER_ID!"
                fi
            done <<< "$vms"
        fi
    fi
}

# Основной цикл мониторинга
monitoring_loop() {
    while true; do
        monitor_services
        if [ "$SERVER_TYPE" == "Proxmox" ]; then
            monitor_vms
        fi
        sleep 60
    done
}

# Функция для обработки команд из Telegram
handle_telegram_commands() {
    local last_update_id=0

    while true; do
        local response=$(curl -s "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/getUpdates?offset=$last_update_id")
        local updates=$(echo "$response" | jq '.result')

        for row in $(echo "${updates}" | jq -r '.[] | @base64'); do
            _jq() {
                echo "$row" | base64 --decode | jq -r "$1"
            }

            local update_id=$(_jq '.update_id')
            local message_text=$(_jq '.message.text')
            local chat_id=$(_jq '.message.chat.id')

            log "Processing update_id: $update_id"

            if [ "$chat_id" == "$TELEGRAM_CHAT_ID" ]; then
                if [ -n "$message_text" ]; then
                    local command=$(echo "$message_text" | awk '{print $1}')
                    local cmd_server_id=$(echo "$message_text" | awk '{print $2}')
                    local args=$(echo "$message_text" | cut -d' ' -f3-)

                    log "Received command: $command from chat_id: $chat_id"

                    if [ "$command" == "/server_id" ]; then
                        send_telegram_message "Server ID: $SERVER_ID"
                    elif [ "$cmd_server_id" == "$SERVER_ID" ]; then
                        case $command in
                            /help)
                                local help_message=$(cat <<EOF
Available commands:
/server_id - Show the server ID.
/list_enabled_services <server_id> - List all enabled services.
/list_vms <server_id> - List all virtual machines (Proxmox only).
/status_vm <server_id> <vm_id> - Show the status of a virtual machine (Proxmox only).
/start_vm <server_id> <vm_id> - Start a virtual machine (Proxmox only).
/stop_vm <server_id> <vm_id> - Stop a virtual machine (Proxmox only).
/restart_vm <server_id> <vm_id> - Restart a virtual machine (Proxmox only).
/status_service <server_id> <service> - Show the status of a service.
/start_service <server_id> <service> - Start a service.
/stop_service <server_id> <service> - Stop a service.
/restart_service <server_id> <service> - Restart a service.
/sudo <server_id> <command> - Execute a command with sudo privileges.
EOF
)
                                send_telegram_message "$help_message"
                                ;;
                            /list_enabled_services)
                                local enabled_services=$(systemctl list-unit-files --type=service --state=enabled)
                                send_telegram_message "$enabled_services"
                                ;;
                            /list_vms)
                                if [ "$SERVER_TYPE" == "Proxmox" ]; then
                                    local vms=$(qm list | awk 'NR>1 {print $1, $2, $3}')
                                    local vm_list=""

                                    while read -r vm; do
                                        local vm_id=$(echo "$vm" | awk '{print $1}')
                                        local vm_name=$(echo "$vm" | awk '{print $2}')
                                        local status=$(echo "$vm" | awk '{print $3}')
                                        vm_list+="$vm_name ($vm_id) - $status\n"
                                    done <<< "$vms"

                                    send_telegram_message "$vm_list"
                                else
                                    send_telegram_message "Error: This command is only available for Proxmox servers."
                                fi
                                ;;
                            /status_vm)
                                if [ "$SERVER_TYPE" == "Proxmox" ]; then
                                    local vm_id=$(echo "$args" | awk '{print $1}')
                                    if [ -z "$vm_id" ]; then
                                        send_telegram_message "Error: vm_id must be specified."
                                    else
                                        local status=$(qm status "$vm_id" 2>&1)
                                        send_telegram_message "Status of VM $vm_id on server $SERVER_ID:\n$status"
                                    fi
                                else
                                    send_telegram_message "Error: This command is only available for Proxmox servers."
                                fi
                                ;;
                            /start_vm)
                                if [ "$SERVER_TYPE" == "Proxmox" ]; then
                                    local vm_id=$(echo "$args" | awk '{print $1}')
                                    if [ -z "$vm_id" ]; then
                                        send_telegram_message "Error: vm_id must be specified."
                                    else
                                        local result=$(qm start "$vm_id" 2>&1)
                                        send_telegram_message "VM $vm_id started on server $SERVER_ID.\n$result"
                                    fi
                                else
                                    send_telegram_message "Error: This command is only available for Proxmox servers."
                                fi
                                ;;
                            /stop_vm)
                                if [ "$SERVER_TYPE" == "Proxmox" ]; then
                                    local vm_id=$(echo "$args" | awk '{print $1}')
                                    if [ -z "$vm_id" ]; then
                                        send_telegram_message "Error: vm_id must be specified."
                                    else
                                        local result=$(qm stop "$vm_id" 2>&1)
                                        send_telegram_message "VM $vm_id stopped on server $SERVER_ID.\n$result"
                                    fi
                                else
                                    send_telegram_message "Error: This command is only available for Proxmox servers."
                                fi
                                ;;
                            /restart_vm)
                                if [ "$SERVER_TYPE" == "Proxmox" ]; then
                                    local vm_id=$(echo "$args" | awk '{print $1}')
                                    if [ -z "$vm_id" ]; then
                                        send_telegram_message "Error: vm_id must be specified."
                                    else
                                        local result_stop=$(qm stop "$vm_id" 2>&1)
                                        local result_start=$(qm start "$vm_id" 2>&1)
                                        send_telegram_message "VM $vm_id restarted on server $SERVER_ID.\nStop result: $result_stop\nStart result: $result_start"
                                    fi
                                else
                                    send_telegram_message "Error: This command is only available for Proxmox servers."
                                fi
                                ;;
                            /status_service)
                                local service=$(echo "$args" | awk '{print $1}')
                                if [ -z "$service" ]; then
                                    send_telegram_message "Error: service must be specified."
                                else
                                    local status=$(systemctl status "$service" 2>&1)
                                    send_telegram_message "Status of service $service on server $SERVER_ID:\n$status"
                                fi
                                ;;
                            /start_service)
                                local service=$(echo "$args" | awk '{print $1}')
                                if [ -z "$service" ]; then
                                    send_telegram_message "Error: service must be specified."
                                else
                                    local result=$(systemctl start "$service" 2>&1)
                                    send_telegram_message "Service $service started on server $SERVER_ID.\n$result"
                                fi
                                ;;
                            /stop_service)
                                local service=$(echo "$args" | awk '{print $1}')
                                if [ -z "$service" ]; then
                                    send_telegram_message "Error: service must be specified."
                                else
                                    local result=$(systemctl stop "$service" 2>&1)
                                    send_telegram_message "Service $service stopped on server $SERVER_ID.\n$result"
                                fi
                                ;;
                            /restart_service)
                                local service=$(echo "$args" | awk '{print $1}')
                                if [ -z "$service" ]; then
                                    send_telegram_message "Error: service must be specified."
                                else
                                    local result_stop=$(systemctl stop "$service" 2>&1)
                                    local result_start=$(systemctl start "$service" 2>&1)
                                    send_telegram_message "Service $service restarted on server $SERVER_ID.\nStop result: $result_stop\nStart result: $result_start"
                                fi
                                ;;
                            /sudo)
                                local sudo_command=$(echo "$args")
                                if [ -z "$sudo_command" ]; then
                                    send_telegram_message "Error: command must be specified."
                                else
                                    local result=$(sudo "$sudo_command" 2>&1)
                                    send_telegram_message "$result"
                                fi
                                ;;
                            *)
                                send_telegram_message "Unknown command: $message_text"
                                ;;
                        esac
                    fi
                fi
            fi

            last_update_id=$(($update_id + 1))
        done

        sleep 5
    done
}

# Отправка сообщения о запуске скрипта
send_telegram_message "Monitoring script started on server $SERVER_ID."

# Запуск обработки команд и мониторинга
handle_telegram_commands &
monitoring_loop
