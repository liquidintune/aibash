#!/bin/bash

CONFIG_FILE="/etc/monitoring_script.conf"
LOG_FILE="/var/log/monitoring_script.log"
PREV_SERVICE_STATUSES="/tmp/prev_service_statuses"
PREV_VM_STATUSES="/tmp/prev_vm_statuses"

install_packages() {
    if ! command -v jq &> /dev/null; then
        printf "Installing jq...\n"
        apt-get update
        apt-get install -y jq
    fi

    if ! command -v curl &> /dev/null; then
        printf "Installing curl...\n"
        apt-get update
        apt-get install -y curl
    fi
}

determine_server_type() {
    if [[ -d "/etc/pve" ]]; then
        SERVER_TYPE="Proxmox"
    else
        SERVER_TYPE="LNMP"
    fi
}

configure_telegram() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        touch "$CONFIG_FILE"
    fi

    if ! grep -q "TELEGRAM_BOT_TOKEN" "$CONFIG_FILE"; then
        read -p "Enter your Telegram Bot Token: " TELEGRAM_BOT_TOKEN
        printf "TELEGRAM_BOT_TOKEN=%s\n" "$TELEGRAM_BOT_TOKEN" >> "$CONFIG_FILE"
    fi

    if ! grep -q "TELEGRAM_CHAT_ID" "$CONFIG_FILE"; then
        read -p "Enter your Telegram Chat ID: " TELEGRAM_CHAT_ID
        printf "TELEGRAM_CHAT_ID=%s\n" "$TELEGRAM_CHAT_ID" >> "$CONFIG_FILE"
    fi

    if ! grep -q "SERVER_ID" "$CONFIG_FILE"; then
        read -p "Enter your unique Server ID: " SERVER_ID
        printf "SERVER_ID=%s\n" "$SERVER_ID" >> "$CONFIG_FILE"
    fi

    source "$CONFIG_FILE"
}

send_telegram_message() {
    local message=$1
    local retry_after

    while : ; do
        response=$(curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
            -d chat_id="$TELEGRAM_CHAT_ID" \
            -d text="$message")

        if echo "$response" | grep -q '"ok":true'; then
            break
        fi

        if echo "$response" | grep -q '"error_code":429'; then
            retry_after=$(echo "$response" | jq '.parameters.retry_after')
            printf "Rate limit exceeded. Retrying after %s seconds.\n" "$retry_after"
            sleep "$retry_after"
        else
            printf "Failed to send message: %s\n" "$response" >&2
            break
        fi
    done
}

log_action() {
    printf "%s - %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE"
}

monitor_services() {
    local services=("nginx" "mysql" "php7.4-fpm")
    declare -A current_statuses

    for service in "${services[@]}"; do
        local status
        status=$(systemctl is-active "$service")
        current_statuses["$service"]="$status"

        if [[ -f "$PREV_SERVICE_STATUSES" ]]; then
            local prev_status
            prev_status=$(grep "$service" "$PREV_SERVICE_STATUSES" | cut -d' ' -f2)
            if [[ "$status" != "$prev_status" ]]; then
                if [[ "$status" = "active" ]]; then
                    send_telegram_message "🟢 Сервис $service активен на сервере $SERVER_ID"
                else
                    send_telegram_message "🔴 Сервис $service не активен на сервере $SERVER_ID"
                fi
            fi
        else
            if [[ "$status" = "active" ]]; then
                send_telegram_message "🟢 Сервис $service активен на сервере $SERVER_ID"
            else
                send_telegram_message "🔴 Сервис $service не активен на сервере $SERVER_ID"
            fi
        fi
    done

    > "$PREV_SERVICE_STATUSES"
    for service in "${!current_statuses[@]}"; do
        printf "%s %s\n" "$service" "${current_statuses[$service]}" >> "$PREV_SERVICE_STATUSES"
    done
}

monitor_vms() {
    if [[ "$SERVER_TYPE" = "Proxmox" ]]; then
        local vms
        vms=$(qm list | awk 'NR>1 {print $1}')
        declare -A current_statuses

        for vm in $vms; do
            local status
            status=$(qm status "$vm" | awk '{print $2}')
            current_statuses["$vm"]="$status"
        done

        if [[ -f "$PREV_VM_STATUSES" ]]; then
            while IFS= read -r line; do
                local vm prev_status
                vm=$(echo "$line" | awk '{print $1}')
                prev_status=$(echo "$line" | awk '{print $2}')

                if [[ "${current_statuses[$vm]}" != "$prev_status" ]]; then
                    if [[ "${current_statuses[$vm]}" = "running" ]]; then
                        send_telegram_message "🟢 ВМ $vm запущена на сервере $SERVER_ID"
                    else
                        send_telegram_message "🔴 ВМ $vm не запущена на сервере $SERVER_ID"
                    fi
                fi
            done < "$PREV_VM_STATUSES"
        else
            for vm in "${!current_statuses[@]}"; do
                if [[ "${current_statuses[$vm]}" = "running" ]]; then
                    send_telegram_message "🟢 ВМ $vm запущена на сервере $SERVER_ID"
                else
                    send_telegram_message "🔴 ВМ $vm не запущена на сервере $SERVER_ID"
                fi
            done
        fi

        > "$PREV_VM_STATUSES"
        for vm in "${!current_statuses[@]}"; do
            printf "%s %s\n" "$vm" "${current_statuses[$vm]}" >> "$PREV_VM_STATUSES"
        done
    fi
}

handle_telegram_commands() {
    local last_update_id=0
    if [[ -f "/tmp/last_update_id" ]]; then
        last_update_id=$(cat /tmp/last_update_id)
    fi

    local updates
    updates=$(curl -s "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/getUpdates?offset=$((last_update_id + 1))")
    echo "$updates" | jq -c '.result[]' | while IFS= read -r update; do
        local update_id command chat_id
        update_id=$(echo "$update" | jq -r '.update_id')
        command=$(echo "$update" | jq -r '.message.text')
        chat_id=$(echo "$update" | jq -r '.message.chat.id')

        last_update_id=$update_id
        echo "$last_update_id" > /tmp/last_update_id

        case $command in
            /server_id)
                send_telegram_message "Server ID: $SERVER_ID"
                ;;
            /help)
                send_telegram_message "Доступные команды:
                /server_id - показать уникальный идентификатор сервера.
                /help - показать список доступных команд.
                /list_enabled_services <server_id> - показать список включенных сервисов на сервере.
                /list_vms <server_id> - показать список виртуальных машин (только для Proxmox).
                /status_vm <server_id> <vm_id> - показать статус виртуальной машины (только для Proxmox).
                /start_vm <server_id> <vm_id> - запустить виртуальную машину (только для Proxmox).
                /stop_vm <server_id> <vm_id> - остановить виртуальную машину (только для Proxmox).
                /restart_vm <server_id> <vm_id> - перезапустить виртуальную машину (только для Proxmox).
                /status_service <server_id> <service> - показать статус сервиса.
                /start_service <server_id> <service> - запустить сервис.
                /stop_service <server_id> <service> - остановить сервис.
                /restart_service <server_id> <service> - перезапустить сервис.
                /sudo <server_id> <command> - выполнить команду с правами суперпользователя."
                ;;
            /list_enabled_services\ *)
                local target_server_id
                target_server_id=$(echo "$command" | awk '{print $2}')
                if [[ "$target_server_id" = "$SERVER_ID" ]]; then
                    local services service_list
                    services=$(systemctl list-units --type=service --state=running | awk '{print $1}')
                    for service in $services; do
                        local status
                        status=$(systemctl is-active "$service")
                        if [[ "$status" = "active" ]]; then
                            service_list+="🟢 $service\n"
                        else
                            service_list+="🔴 $service\n"
                        fi
                    done
                    send_telegram_message "Включенные сервисы на сервере $SERVER_ID:\n$service_list"
                fi
                ;;
            /list_vms\ *)
                local target_server_id
                target_server_id=$(echo "$command" | awk '{print $2}')
                if [[ "$SERVER_TYPE" = "Proxmox" && "$target_server_id" = "$SERVER_ID" ]]; then
                    local vms vm_list
                    vms=$(qm list)
                    while IFS= read -r line; do
                        local vm_id vm_status
                        vm_id=$(echo "$line" | awk '{print $1}')
                        vm_status=$(qm status "$vm_id" | awk '{print $2}')
                        if [[ "$vm_status" = "running" ]]; then
                            vm_list+="🟢 VM $vm_id\n"
                        else
                            vm_list+="🔴 VM $vm_id\n"
                        fi
                    done <<< "$(echo "$vms" | awk 'NR>1')"
                    send_telegram_message "Виртуальные машины на сервере $SERVER_ID:\n$vm_list"
                fi
                ;;
            /status_vm\ *)
                local target_server_id vm_id
                target_server_id=$(echo "$command" | awk '{print $2}')
                vm_id=$(echo "$command" | awk '{print $3}')
                if [[ "$SERVER_TYPE" = "Proxmox" && "$target_server_id" = "$SERVER_ID" ]]; then
                    local status
                    status=$(qm status "$vm_id" | awk '{print $2}')
                    send_telegram_message "ВМ $vm_id на сервере $SERVER_ID имеет статус $status"
                fi
                ;;
            /start_vm\ *)
                local target_server_id vm_id
                target_server_id=$(echo "$command" | awk '{print $2}')
                vm_id=$(echo "$command" | awk '{print $3}')
                if [[ "$SERVER_TYPE" = "Proxmox" && "$target_server_id" = "$SERVER_ID" ]]; then
                    qm start "$vm_id"
                    send_telegram_message "ВМ $vm_id на сервере $SERVER_ID запущена"
                fi
                ;;
            /stop_vm\ *)
                local target_server_id vm_id
                target_server_id=$(echo "$command" | awk '{print $2}')
                vm_id=$(echo "$command" | awk '{print $3}')
                if [[ "$SERVER_TYPE" = "Proxmox" && "$target_server_id" = "$SERVER_ID" ]]; then
                    qm stop "$vm_id"
                    send_telegram_message "ВМ $vm_id на сервере $SERVER_ID остановлена"
                fi
                ;;
            /restart_vm\ *)
                local target_server_id vm_id
                target_server_id=$(echo "$command" | awk '{print $2}')
                vm_id=$(echo "$command" | awk '{print $3}')
                if [[ "$SERVER_TYPE" = "Proxmox" && "$target_server_id" = "$SERVER_ID" ]]; then
                    qm restart "$vm_id"
                    send_telegram_message "ВМ $vm_id на сервере $SERVER_ID перезапущена"
                fi
                ;;
            /status_service\ *)
                local target_server_id service
                target_server_id=$(echo "$command" | awk '{print $2}')
                service=$(echo "$command" | awk '{print $3}')
                if [[ "$target_server_id" = "$SERVER_ID" ]]; then
                    local status
                    status=$(systemctl is-active "$service")
                    send_telegram_message "Сервис $service на сервере $SERVER_ID имеет статус $status"
                fi
                ;;
            /start_service\ *)
                local target_server_id service
                target_server_id=$(echo "$command" | awk '{print $2}')
                service=$(echo "$command" | awk '{print $3}')
                if [[ "$target_server_id" = "$SERVER_ID" ]]; then
                    systemctl start "$service"
                    send_telegram_message "Сервис $service на сервере $SERVER_ID запущен"
                fi
                ;;
            /stop_service\ *)
                local target_server_id service
                target_server_id=$(echo "$command" | awk '{print $2}')
                service=$(echo "$command" | awk '{print $3}')
                if [[ "$target_server_id" = "$SERVER_ID" ]]; then
                    systemctl stop "$service"
                    send_telegram_message "Сервис $service на сервере $SERVER_ID остановлен"
                fi
                ;;
            /restart_service\ *)
                local target_server_id service
                target_server_id=$(echo "$command" | awk '{print $2}')
                service=$(echo "$command" | awk '{print $3}')
                if [[ "$target_server_id" = "$SERVER_ID" ]]; then
                    systemctl restart "$service"
                    send_telegram_message "Сервис $service на сервере $SERVER_ID перезапущен"
                fi
                ;;
            /sudo\ *)
                local target_server_id cmd
                target_server_id=$(echo "$command" | awk '{print $2}')
                cmd=$(echo "$command" | cut -d' ' -f3-)
                if [[ "$target_server_id" = "$SERVER_ID" ]]; then
                    local output
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

monitoring_loop() {
    while true; do
        if [[ "$SERVER_TYPE" = "Proxmox" ]]; then
            monitor_vms
        else
            monitor_services
        fi

        handle_telegram_commands
        sleep 5
    done
}

main() {
    install_packages
    determine_server_type
    configure_telegram
    log_action "Starting monitoring loop"
    monitoring_loop
}

main "$@"
