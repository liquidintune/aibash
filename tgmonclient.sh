#!/bin/bash

set -e

# Функция для определения операционной системы и установки необходимых пакетов
install_packages() {
    if [[ -f /etc/debian_version ]]; then
        if ! command -v jq &> /dev/null; then
            apt-get update
            apt-get install -y jq curl
        fi
    elif [[ -f /etc/redhat-release ]]; then
        if ! command -v jq &> /dev/null; then
            yum install -y epel-release
            yum install -y jq curl
        fi
    else
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

# Определение типа сервера и установка набора сервисов для мониторинга
SERVER_TYPE=$(determine_server_type)
if [ "$SERVER_TYPE" == "Proxmox" ]; then
    DEFAULT_SERVICES_TO_MONITOR="pve-cluster,pvedaemon,qemu-server,pveproxy"
else
    DEFAULT_SERVICES_TO_MONITOR="nginx,mysql,php7.4-fpm"
fi

# Запрос конфигурации у пользователя
if [ ! -f ~/.telegram_bot_config ]; then
    read -p "Enter Telegram bot token: " TELEGRAM_BOT_TOKEN
    read -p "Enter Telegram group chat ID: " TELEGRAM_CHAT_ID
    read -p "Enter unique server ID: " SERVER_ID
    echo "TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN" > ~/.telegram_bot_config
    echo "TELEGRAM_CHAT_ID=$TELEGRAM_CHAT_ID" >> ~/.telegram_bot_config
    echo "SERVER_ID=$SERVER_ID" >> ~/.telegram_bot_config
    echo "SERVICES_TO_MONITOR=$DEFAULT_SERVICES_TO_MONITOR" >> ~/.telegram_bot_config
else
    source ~/.telegram_bot_config
fi

# Переменные для хранения предыдущих состояний
declare -A previous_service_statuses
declare -A previous_vm_statuses

# Функция для отправки сообщений в Telegram
send_telegram_message() {
    local message=$1
    local buttons=$2
    local response
    local retry_after

    while true; do
        if [ -z "$buttons" ]; then
            response=$(curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
                -d chat_id="$TELEGRAM_CHAT_ID" \
                -d text="$message")
        else
            response=$(curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
                -d chat_id="$TELEGRAM_CHAT_ID" \
                -d text="$message" \
                -d reply_markup="$buttons")
        fi

        local ok=$(echo "$response" | jq '.ok')
        if [ "$ok" == "true" ]; then
            break
        else
            retry_after=$(echo "$response" | jq '.parameters.retry_after')
            if [ -n "$retry_after" ] && [ "$retry_after" != "null" ]; then
                sleep "$retry_after"
            else
                sleep 1
            fi
        fi
    done
}

# Функция для мониторинга сервисов systemd
monitor_services() {
    local services=($(echo $SERVICES_TO_MONITOR | tr ',' ' '))
    for service in "${services[@]}"; do
        local current_status=$(systemctl is-active $service)
        if [ "${previous_service_statuses[$service]}" != "$current_status" ]; then
            previous_service_statuses[$service]=$current_status
            if [ "$current_status" != "active" ]; then
                send_telegram_message "Service $service is not running on server $SERVER_ID!"
            fi
        fi
    done
}

# Функция для мониторинга виртуальных машин
monitor_vms() {
    local vms=$(qm list | awk 'NR>1 {print $1, $2, $3}')

    while read -r vm; do
        local vm_id=$(echo $vm | awk '{print $1}')
        local vm_name=$(echo $vm | awk '{print $2}')
        local status=$(echo $vm | awk '{print $3}')

        if [ "${previous_vm_statuses[$vm_id]}" != "$status" ]; then
            previous_vm_statuses[$vm_id]=$status
            if [ "$status" != "running" ]; then
                send_telegram_message "VM $vm is not running on server $SERVER_ID!"
            fi

            local inline_keyboard=$(cat <<EOF
{
    "inline_keyboard": [
        [
            {"text": "Status", "callback_data": "/status_vm $SERVER_ID $vm_id"},
            {"text": "Start", "callback_data": "/start_vm $SERVER_ID $vm_id"},
            {"text": "Restart", "callback_data": "/restart_vm $SERVER_ID $vm_id"}
        ]
    ]
}
EOF
)
            local buttons=$(echo $inline_keyboard | jq -c .)
            send_telegram_message "$vm_name ($vm_id) - $status" "$buttons"
        fi
    done <<< "$vms"
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
        local updates=$(echo $response | jq '.result')

        for row in $(echo "${updates}" | jq -r '.[] | @base64'); do
            _jq() {
                echo ${row} | base64 --decode | jq -r ${1}
            }

            local update_id=$(_jq '.update_id')
            local message_text=$(_jq '.message.text')
            local callback_query_id=$(_jq '.callback_query.id')
            local callback_data=$(_jq '.callback_query.data')
            local chat_id=$(_jq '.message.chat.id')
            local message_id=$(_jq '.callback_query.message.message_id')
            local from_id=$(_jq '.callback_query.from.id')

            if [ "$chat_id" == "$TELEGRAM_CHAT_ID" ]; then
                local command=$(echo $message_text | awk '{print $1}')
                local cmd_server_id=$(echo $message_text | awk '{print $2}')
                local args=$(echo $message_text | cut -d' ' -f3-)

                if [ "$command" == "/server_id" ]; then
                    send_telegram_message "Server ID: $SERVER_ID"
                elif [ "$command" == "/help" ]; then
                    local help_message=$(cat <<EOF
Available commands:
/server_id - Show the server ID.
/list_enabled_services <server_id> - List all enabled services.
/list_vms <server_id> - List all virtual machines.
/start_vm <server_id> <vm_id> - Start a virtual machine.
/stop_vm <server_id> <vm_id> - Stop a virtual machine.
/restart_vm <server_id> <vm_id> - Restart a virtual machine.
/sudo <server_id> <command> - Execute a command with sudo privileges.

To get the status, start or restart a VM, use the buttons provided with the VM list.
EOF
)
                    send_telegram_message "$help_message"
                elif [ "$cmd_server_id" == "$SERVER_ID" ]; then
                    case $command in
                        /list_enabled_services)
                            local enabled_services=$(systemctl list-unit-files --type=service --state=enabled)
                            send_telegram_message "$enabled_services"
                            ;;
                        /list_vms)
                            monitor_vms
                            ;;
                        /start_vm)
                            local vm_id=$(echo $args | awk '{print $1}')
                            qm start $vm_id
                            send_telegram_message "VM $vm_id started on server $SERVER_ID."
                            ;;
                        /stop_vm)
                            local vm_id=$(echo $args | awk '{print $1}')
                            qm stop $vm_id
                            send_telegram_message "VM $vm_id stopped on server $SERVER_ID."
                            ;;
                        /restart_vm)
                            local vm_id=$(echo $args | awk '{print $1}')
                            qm stop $vm_id
                            qm start $vm_id
                            send_telegram_message "VM $vm_id restarted on server $SERVER_ID."
                            ;;
                        /sudo)
                            local sudo_command=$(echo $message_text | cut -d' ' -f3-)
                            local result=$($sudo_command 2>&1)
                            send_telegram_message "$result"
                            ;;
                        *)
                            send_telegram_message "Unknown command: $message_text"
                            ;;
                    esac
                fi
            elif [ "$callback_query_id" != "" ]; then
                local callback_command=$(echo $callback_data | awk '{print $1}')
                local callback_server_id=$(echo $callback_data | awk '{print $2}')
                local callback_args=$(echo $callback_data | cut -d' ' -f3-)
                if [ "$callback_server_id" == "$SERVER_ID" ]; then
                    case $callback_command in
                        /status_vm)
                            local vm_id=$callback_args
                            local status=$(qm status $vm_id)
                            curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/answerCallbackQuery" \
                                -d callback_query_id="$callback_query_id" \
                                -d text="$status"
                            ;;
                        /start_vm)
                            local vm_id=$callback_args
                            qm start $vm_id
                            curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/answerCallbackQuery" \
                                -d callback_query_id="$callback_query_id" \
                                -d text="VM $vm_id started."
                            ;;
                        /restart_vm)
                            local vm_id=$callback_args
                            qm stop $vm_id
                            qm start $vm_id
                            curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/answerCallbackQuery" \
                                -d callback_query_id="$callback_query_id" \
                                -d text="VM $vm_id restarted."
                            ;;
                        *)
                            curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/answerCallbackQuery" \
                                -d callback_query_id="$callback_query_id" \
                                -d text="Unknown command."
                            ;;
                    esac
                fi
            fi

            last_update_id=$(($update_id + 1))
        done

        sleep 5
    done
}

# Запуск обработки команд и мониторинга
handle_telegram_commands &
monitoring_loop
