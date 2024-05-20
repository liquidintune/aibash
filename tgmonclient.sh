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
                    send_telegram_message "🟢 Сервис $service активен на сервере $SERVER_ID"
                else
                    send_telegram_message "🔴 Сервис $service не активен на сервере $SERVER_ID"
                fi
            fi
        else
            if [ "$status" = "active" ]; then
                send_telegram_message "🟢 Сервис $service активен на сервере $SERVER_ID"
            else
                send_telegram_message "🔴 Сервис $service не активен на сервере $SERVER_ID"
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
                        send_telegram_message "🟢 ВМ $vm запущена на сервере $SERVER_ID"
                    else
                        send_telegram_message "🔴 ВМ $vm не запущена на сервере $SERVER_ID"
                    fi
                fi
            else
                if [ "$status" = "running" ]; then
                    send_telegram_message "🟢 ВМ $vm запущена на сервере $SERVER_ID"
                else
                    send_telegram_message "🔴 ВМ $vm не запущена на сервере $SERVER_ID"
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
    local last_update_id=0
    if [ -f "/tmp/last_update_id" ]; then
        last_update_id=$(cat /tmp/last_update_id)
    fi

    updates=$(curl -s "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/getUpdates?offset=$((last_update_id + 1))")
    echo $updates | jq -c '.result[]' | while read update; do
        update_id=$(echo $update | jq -r '.update_id')
        command=$(echo $update | jq -r '.message.text')
        chat_id=$(echo $update | jq -r '.message.chat.id')

        last_update_id=$update_id
        echo $last_update_id > /tmp/last_update_id

        case $command in
            /server_id)
                send_telegram_message "Server ID: $SERVER_ID"
                ;;
            /help)
                send_telegram_message "Доступные команды:
<code>/server_id</code> - показать уникальный идентификатор сервера.
<code>/help</code> - показать список доступных команд.
<code>/list_enabled_services <server_id></code> - показать список включенных сервисов на сервере.
<code>/list_vms <server_id></code> - показать список виртуальных машин (только для Proxmox).
<code>/status_vm <server_id> <vm_id></code> - показать статус виртуальной машины (только для Proxmox).
<code>/start_vm <server_id> <vm_id></code> - запустить виртуальную машину (только для Proxmox).
<code>/stop_vm <server_id> <vm_id></code> - остановить виртуальную машину (только для Proxmox).
<code>/restart_vm <server_id> <vm_id></code> - перезапустить виртуальную машину (только для Proxmox).
<code>/status_service <server_id> <service></code> - показать статус сервиса.
<code>/start_service <server_id> <service></code> - запустить сервис.
<code>/stop_service <server_id> <service></code> - остановить сервис.
<code>/restart_service <server_id> <service></code> - перезапустить сервис.
<code>/sudo <server_id> <command></code> - выполнить команду с правами суперпользователя."
                ;;
            /list_enabled_services\ *)
                target_server_id=$(echo $command | awk '{print $2}')
                if [ "$target_server_id" = "$SERVER_ID" ]; then
                    services=$(systemctl list-units --type=service --state=running | awk '{print $1}')
                    send_telegram_message "Включенные сервисы на сервере $SERVER_ID:\n$services"
                fi
                ;;
            /list_vms\ *)
                target_server_id=$(echo $command | awk '{print $2}')
                if [ "$SERVER_TYPE" = "Proxmox" ] && [ "$target_server_id" = "$SERVER_ID" ]; then
                    vms=$(qm list)
                    send_telegram_message "Виртуальные машины на сервере $SERVER_ID:\n$vms"
                fi
                ;;
            /status_vm\ *)
                target_server_id=$(echo $command | awk '{print $2}')
                vm_id=$(echo $command | awk '{print $3}')
                if [ "$SERVER_TYPE" = "Proxmox" ] && [ "$target_server_id" = "$SERVER_ID" ]; then
                    status=$(qm status $vm_id | awk '{print $2}')
                    send_telegram_message "ВМ $vm_id на сервере $SERVER_ID имеет статус $status"
                fi
                ;;
            /start_vm\ *)
                target_server_id=$(echo $command | awk '{print $2}')
                vm_id=$(echo $command | awk '{print $3}')
                if [ "$SERVER_TYPE" = "Proxmox" ] && [ "$target_server_id" = "$SERVER_ID" ]; then
                    qm start $vm_id
                    send_telegram_message "ВМ $vm_id на сервере $SERVER_ID запущена"
                fi
                ;;
            /stop_vm\ *)
                target_server_id=$(echo $command | awk '{print $2}')
                vm_id=$(echo $command | awk '{print $3}')
                if [ "$SERVER_TYPE" = "Proxmox" ] && [ "$target_server_id" = "$SERVER_ID" ]; then
                    qm stop $vm_id
                    send_telegram_message "ВМ $vm_id на сервере $SERVER_ID остановлена"
                fi
                ;;
            /restart_vm\ *)
                target_server_id=$(echo $command | awk '{print $2}')
                vm_id=$(echo $command | awk '{print $3}')
                if [ "$SERVER_TYPE" = "Proxmox" ] && [ "$target_server_id" = "$SERVER_ID" ]; then
                    qm restart $vm_id
                    send_telegram_message "ВМ $vm_id на сервере $SERVER_ID перезапущена"
                fi
                ;;
            /status_service\ *)
                target_server_id=$(echo $command | awk '{print $2}')
                service=$(echo $command | awk '{print $3}')
                if [ "$target_server_id" = "$SERVER_ID" ]; then
                    status=$(systemctl is-active $service)
                    send_telegram_message "Сервис $service на сервере $SERVER_ID имеет статус $status"
                fi
                ;;
            /start_service\ *)
                target_server_id=$(echo $command | awk '{print $2}')
                service=$(echo $command | awk '{print $3}')
                if [ "$target_server_id" = "$SERVER_ID" ]; then
                    systemctl start $service
                    send_telegram_message "Сервис $service на сервере $SERVER_ID запущен"
                fi
                ;;
            /stop_service\ *)
                target_server_id=$(echo $command | awk '{print $2}')
                service=$(echo $command | awk '{print $3}')
                if [ "$target_server_id" = "$SERVER_ID" ]; then
                    systemctl stop $service
                    send_telegram_message "Сервис $service на сервере $SERVER_ID остановлен"
                fi
                ;;
            /restart_service\ *)
                target_server_id=$(echo $command | awk '{print $2}')
                service=$(echo $command | awk '{print $3}')
                if [ "$target_server_id" = "$SERVER_ID" ]; then
                    systemctl restart $service
                    send_telegram_message "Сервис $service на сервере $SERVER_ID перезапущен"
                fi
                ;;
            /sudo\ *)
                target_server_id=$(echo $command | awk '{print $2}')
                cmd=$(echo $command | cut -d' ' -f3-)
                if [ "$target_server_id" = "$SERVER_ID" ]; then
                    output=$(sudo bash -c "$cmd")
                    send_telegram_message "Команда '$cmd' выполнена на сервере $SERVER_ID. Вывод:\n$output"
                fi
                ;;
            *)
                send_telegram_message "Неизвестная команда."
                ;;
        esac
    done
}

# Основной цикл мониторинга
monitoring_loop() {
    while true; do
        if [ "$SERVER_TYPE" = "Proxmox" ]; then
            monitor_vms
        else
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
