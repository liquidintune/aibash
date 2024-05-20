#!/bin/bash

# Путь к файлу конфигурации
CONFIG_FILE="/etc/monitoring_script.conf"

# Лог файл
LOG_FILE="/var/log/monitoring_script.log"

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
    curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
        -d chat_id=$TELEGRAM_CHAT_ID \
        -d text="$message" \
        -d parse_mode="HTML"
}

# Логирование
log_action() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> $LOG_FILE
}

# Мониторинг состояния сервисов
monitor_services() {
    local services=("nginx" "mysql" "php7.4-fpm")
    for service in "${services[@]}"; do
        status=$(systemctl is-active $service)
        if [ "$status" = "active" ]; then
            send_telegram_message "🟢 Service $service is active"
        else
            send_telegram_message "🔴 Service $service is inactive"
        fi
    done
}

# Мониторинг состояния виртуальных машин (только для Proxmox)
monitor_vms() {
    if [ "$SERVER_TYPE" = "Proxmox" ]; then
        vms=$(qm list | awk 'NR>1 {print $1}')
        for vm in $vms; do
            status=$(qm status $vm | awk '{print $2}')
            if [ "$status" = "running" ]; then
                send_telegram_message "🟢 VM $vm is running"
            else
                send_telegram_message "🔴 VM $vm is not running"
            fi
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
                send_telegram_message "Available commands: /server_id, /help, /list_enabled_services, /list_vms, /status_vm, /start_vm, /stop_vm, /restart_vm, /status_service, /start_service, /stop_service, /restart_service, /sudo"
                ;;
            /list_enabled_services)
                services=$(systemctl list-units --type=service --state=running | awk '{print $1}')
                send_telegram_message "Enabled services:\n$services"
                ;;
            /list_vms)
                if [ "$SERVER_TYPE" = "Proxmox" ]; then
                    vms=$(qm list)
                    send_telegram_message "VMs:\n$vms"
                else
                    send_telegram_message "Command not supported on this server type."
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
        monitor_services
        monitor_vms
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
