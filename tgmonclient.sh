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

# Установка пакетов
install_packages

# Запрос конфигурации у пользователя
if [ ! -f ~/.telegram_bot_config ]; then
    read -p "Enter Telegram bot token: " TELEGRAM_BOT_TOKEN
    read -p "Enter Telegram group chat ID: " TELEGRAM_CHAT_ID
    read -p "Enter unique server ID: " SERVER_ID
    echo "TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN" > ~/.telegram_bot_config
    echo "TELEGRAM_CHAT_ID=$TELEGRAM_CHAT_ID" >> ~/.telegram_bot_config
    echo "SERVER_ID=$SERVER_ID" >> ~/.telegram_bot_config
else
    source ~/.telegram_bot_config
fi

# Функция для отправки сообщений в Telegram
send_telegram_message() {
    local message=$1
    curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" -d chat_id="$TELEGRAM_CHAT_ID" -d text="$message"
}

# Функция для мониторинга сервисов systemd
monitor_services() {
    local services=("pve-cluster" "pvedaemon" "qemu-server" "pveproxy")
    for service in "${services[@]}"; do
        if ! systemctl is-active --quiet $service; then
            send_telegram_message "Service $service is not running on server $SERVER_ID!"
        fi
    done
}

# Функция для мониторинга виртуальных машин
monitor_vms() {
    local vms=$(qm list --output-format json)
    local vms_status=$(echo $vms | jq -r '.[] | "\(.vmid): \(.name) (\(.status))"')
    for vm in $vms_status; do
        local status=$(echo $vm | awk '{print $3}')
        if [ "$status" != "(running)" ]; then
            send_telegram_message "VM $vm is not running on server $SERVER_ID!"
        fi
    done
}

# Основной цикл мониторинга
monitoring_loop() {
    while true; do
        monitor_services
        if [ "$HV" == "true" ]; then
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
            local chat_id=$(_jq '.message.chat.id')

            if [ "$chat_id" == "$TELEGRAM_CHAT_ID" ]; then
                local command=$(echo $message_text | awk '{print $1}')
                local cmd_server_id=$(echo $message_text | awk '{print $2}')
                local args=$(echo $message_text | cut -d' ' -f3-)

                if [ "$command" == "/server_id" ]; then
                    send_telegram_message "Server ID: $SERVER_ID"
                elif [ "$cmd_server_id" == "$SERVER_ID" ]; then
                    case $command in
                        /list_enabled_services)
                            local enabled_services=$(systemctl list-unit-files --type=service --state=enabled)
                            send_telegram_message "$enabled_services"
                            ;;
                        /list_vms)
                            local vm_list=$(qm list)
                            send_telegram_message "$vm_list"
                            ;;
                        /start_vm)
                            local vm_id=$args
                            qm start $vm_id
                            send_telegram_message "VM $vm_id started on server $SERVER_ID."
                            ;;
                        /stop_vm)
                            local vm_id=$args
                            qm stop $vm_id
                            send_telegram_message "VM $vm_id stopped on server $SERVER_ID."
                            ;;
                        /sudo)
                            local sudo_command=$(echo $message_text | cut -d' ' -f3-)
                            local result=$(sudo $sudo_command 2>&1)
                            send_telegram_message "$result"
                            ;;
                        *)
                            send_telegram_message "Unknown command: $message_text"
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