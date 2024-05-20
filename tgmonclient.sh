#!/bin/bash

# Путь к файлу конфигурации
CONFIG_FILE="/etc/monitoring_script.conf"

# Лог файл
LOG_FILE="/var/log/monitoring_script.log"

# Храним предыдущие состояния сервисов и виртуальных машин
PREV_SERVICE_STATUSES="/tmp/prev_service_statuses"
PREV_VM_STATUSES="/tmp/prev_vm_statuses"

# Проверка и установка необходимых пакетов
install_packages() {
    if ! command -v jq &> /dev/null; then
        echo "Installing jq..."
        apt-get update
        apt-get install -y jq
    fi

    if ! command -v curl &> /dev/null; then
        echo "Installing curl..."
        apt-get update
        apt-get install -y curl
    fi
}

# Определение типа сервера
determine_server_type() {
    if [ -d "/etc/pve" ]; then
        SERVER_TYPE="Proxmox"
    else
        SERVER_TYPE="LNMP"
    fi
}

# Настройка конфигурации Telegram
configure_telegram() {
    if [ ! -f "$CONFIG_FILE" ]; then
        touch $CONFIG_FILE
    fi

    if ! grep -q "TELEGRAM_BOT_TOKEN" $CONFIG_FILE; then
        read -p "Enter your Telegram Bot Token: " TELEGRAM_BOT_TOKEN
        echo "TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN" >> $CONFIG_FILE
    fi

    if ! grep -q "TELEGRAM_CHAT_ID" $CONFIG_FILE; then
        read -p "Enter your Telegram Chat ID: " TELEGRAM_CHAT_ID
        echo "TELEGRAM_CHAT_ID=$TELEGRAM_CHAT_ID" >> $CONFIG_FILE
    fi

    if ! grep -q "SERVER_ID" $CONFIG_FILE; then
        read -p "Enter your unique Server ID: " SERVER_ID
        echo "SERVER_ID=$SERVER_ID" >> $CONFIG_FILE
    fi

    source $CONFIG_FILE
}

# Отправка уведомлений в Telegram
send_telegram_message() {
    local message=$1
    local retry_after=0

    while : ; do
        response=$(curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
            -d chat_id=$TELEGRAM_CHAT_ID \
            -d text="$message" \
            -d parse_mode="HTML")

        if echo "$response" | grep -q '"ok":true'; then
            break
        fi

        if echo "$response" | grep -q '"error_code":429'; then
            retry_after=$(echo "$response" | jq '.parameters.retry_after')
            echo "Rate limit exceeded. Retrying after $retry_after seconds."
            sleep $retry_after
        else
            echo "Failed to send message: $response"
            break
        fi
    done
}

# Логирование
log_action() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> $LOG_FILE
}

# Мониторинг состояния сервисов
monitor_services() {
    local services=("nginx" "mysql" "php7.4-fpm")
    declare -A current_statuses

    for service in "${services[@]}"; do
        status=$(systemctl is-active $service)
        current_statuses[$service]=$status

        if [ -f "$PREV_SERVICE_STATUSES" ]; then
            prev_status=$(grep "$service" "$PREV_SERVICE_STATUSES" | cut -d' ' -f2)
            if [ "$status" != "$prev_status" ]; then
                if [ "$status" = "active" ]; then
                    send_telegram_message "🟢 Service $service is active on server $SERVER_ID"
                else
                    send_telegram_message "🔴 Service $service is inactive on server $SERVER_ID"
                fi
            fi
        else
            if [ "$status" = "active" ]; then
                send_telegram_message "🟢 Service $service is active on server $SERVER_ID"
            else
                send_telegram_message "🔴 Service $service is inactive on server $SERVER_ID"
            fi
        fi
    done

    # Сохраняем текущие статусы
    > "$PREV_SERVICE_STATUSES"
    for service in "${!current_statuses[@]}"; do
        echo "$service ${current_statuses[$service]}" >> "$PREV_SERVICE_STATUSES"
    done
}

# Мониторинг состояния виртуальных машин (только для Proxmox)
monitor_vms() {
    if [ "$SERVER_TYPE" = "Proxmox" ]; then
        vms=$(qm list | awk 'NR>1 {print $1}')
        declare -A current_statuses

        for vm in $vms; do
            status=$(qm status $vm | awk '{print $2}')
            current_statuses[$vm]=$status

            if [ -f "$PREV_VM_STATUSES" ]; then
                prev_status=$(grep "$vm" "$PREV_VM_STATUSES" | cut -d' ' -f2)
                if [ "$status" != "$prev_status" ]; then
                    if [ "$status" = "running" ]; then
                        send_telegram_message "🟢 VM $vm is running on server $SERVER_ID"
                    else
                        send_telegram_message "🔴 VM $vm is not running on server $SERVER_ID"
                    fi
                fi
            else
                if [ "$status" = "running" ]; then
                    send_telegram_message "🟢 VM $vm is running on server $SERVER_ID"
                else
                    send_telegram_message "🔴 VM $vm is not running on server $SERVER_ID"
                fi
            fi
        done

        # Сохраняем текущие статусы
        > "$PREV_VM_STATUSES"
        for vm in "${!current_statuses[@]}"; do
            echo "$vm ${current_statuses[$vm]}" >> "$PREV_VM_STATUSES"
        done
    fi
}

# Обработка команд из Telegram
handle_telegram_commands() {
    updates=$(curl -s "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/getUpdates")
    echo $updates | jq -c '.result[]' | while read update; do
        command=$(echo $update | jq -r '.message.text')
        chat_id=$(echo $update | jq -r '.message.chat.id')
        
        case $command in
            /server_id)
                send_telegram_message "Server ID: $SERVER_ID"
                ;;
            /help)
                send_telegram_message "Available commands: /server_id, /help, /list_enabled_services <server_id>, /list_vms <server_id>, /status_vm <server_id> <vm_id>, /start_vm <server_id> <vm_id>, /stop_vm <server_id> <vm_id>, /restart_vm <server_id> <vm_id>, /status_service <server_id> <service>, /start_service <server_id> <service>, /stop_service <server_id> <service>, /restart_service <server_id> <service>, /sudo <server_id> <command>"
                ;;
            /list_enabled_services\ *)
                target_server_id=$(echo $command | awk '{print $2}')
                if [ "$target_server_id" = "$SERVER_ID" ]; then
                    services=$(systemctl list-units --type=service --state=running | awk '{print $1}')
                    send_telegram_message "Enabled services on server $SERVER_ID:\n$services"
                fi
                ;;
            /list_vms\ *)
                target_server_id=$(echo $command | awk '{print $2}')
                if [ "$SERVER_TYPE" = "Proxmox" ] && [ "$target_server_id" = "$SERVER_ID" ]; then
                    vms=$(qm list)
                    send_telegram_message "VMs on server $SERVER_ID:\n$vms"
                fi
                ;;
            /status_vm\ *)
                target_server_id=$(echo $command | awk '{print $2}')
                vm_id=$(echo $command | awk '{print $3}')
                if [ "$SERVER_TYPE" = "Proxmox" ] && [ "$target_server_id" = "$SERVER_ID" ]; then
                    status=$(qm status $vm_id | awk '{print $2}')
                    send_telegram_message "VM $vm_id on server $SERVER_ID is $status"
                fi
                ;;
            /start_vm\ *)
                target_server_id=$(echo $command | awk '{print $2}')
                vm_id=$(echo $command | awk '{print $3}')
                if [ "$SERVER_TYPE" = "Proxmox" ] && [ "$target_server_id" = "$SERVER_ID" ]; then
                    qm start $vm_id
                    send_telegram_message "VM $vm_id on server $SERVER_ID started"
                fi
                ;;
            /stop_vm\ *)
                target_server_id=$(echo $command | awk '{print $2}')
                vm_id=$(echo $command | awk '{print $3}')
                if [ "$SERVER_TYPE" = "Proxmox" ] && [ "$target_server_id" = "$SERVER_ID" ]; then
                    qm stop $vm_id
                    send_telegram_message "VM $vm_id on server $SERVER_ID stopped"
                fi
                ;;
            /restart_vm\ *)
                target_server_id=$(echo $command | awk '{print $2}')
                vm_id=$(echo $command | awk '{print $3}')
                if [ "$SERVER_TYPE" = "Proxmox" ] && [ "$target_server_id" = "$SERVER_ID" ]; then
                    qm restart $vm_id
                    send_telegram_message "VM $vm_id on server $SERVER_ID restarted"
                fi
                ;;
            /status_service\ *)
                target_server_id=$(echo $command | awk '{print $2}')
                service=$(echo $command | awk '{print $3}')
                if [ "$target_server_id" = "$SERVER_ID" ]; then
                    status=$(systemctl is-active $service)
                    send_telegram_message "Service $service on server $SERVER_ID is $status"
                fi
                ;;
            /start_service\ *)
                target_server_id=$(echo $command | awk '{print $2}')
                service=$(echo $command | awk '{print $3}')
                if [ "$target_server_id" = "$SERVER_ID" ]; then
                    systemctl start $service
                    send_telegram_message "Service $service on server $SERVER_ID started"
                fi
                ;;
            /stop_service\ *)
                target_server_id=$(echo $command | awk '{print $2}')
                service=$(echo $command | awk '{print $3}')
                if [ "$target_server_id" = "$SERVER_ID" ]; then
                    systemctl stop $service
                    send_telegram_message "Service $service on server $SERVER_ID stopped"
                fi
                ;;
            /restart_service\ *)
                target_server_id=$(echo $command | awk '{print $2}')
                service=$(echo $command | awk '{print $3}')
                if [ "$target_server_id" = "$SERVER_ID" ]; then
                    systemctl restart $service
                    send_telegram_message "Service $service on server $SERVER_ID restarted"
                fi
                ;;
            /sudo\ *)
                target_server_id=$(echo $command | awk '{print $2}')
                cmd=$(echo $command | cut -d' ' -f3-)
                if [ "$target_server_id" = "$SERVER_ID" ]; then
                    output=$(sudo bash -c "$cmd")
                    send_telegram_message "Command '$cmd' executed on server $SERVER_ID. Output:\n$output"
                fi
                ;;
            *)
                send_telegram_message "Unknown command."
                ;;
        esac
    done
}

# Основной цикл мониторинга
monitoring_loop() {
    while true; do
        if [ "$SERVER_TYPE" = "Proxmox" ]; then
            monitor_vms
        fi

        if [ "$SERVER_TYPE" != "Proxmox" ]; then
            monitor_services
        fi

        handle_telegram_commands
        sleep 60
    done
}

# Инициализация
install_packages
determine_server_type
configure_telegram

# Запуск основного цикла мониторинга
log_action "Starting monitoring loop"
monitoring_loop
