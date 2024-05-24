#!/bin/bash

set -e
LOG_FILE="/var/log/monitoring_script.log"
CONFIG_FILE="$HOME/.telegram_bot_config"
SECRET_FILE="$HOME/.telegram_bot_secret"
STATUS_FILE="/tmp/monitoring_status"
VM_STATUS_FILE="/tmp/vm_monitoring_status"
DISK_THRESHOLD=10
CPU_THRESHOLD=90
MEM_THRESHOLD=90
TEMP_THRESHOLD=80

log() {
    local message="$1"
    echo "$(date +'%Y-%m-%d %H:%M:%S') - $message" >> "$LOG_FILE"
}

install_packages() {
    if [[ -f /etc/debian_version ]]; then
        log "Debian-based OS detected"
        apt-get update
        apt-get install -y jq curl lm-sensors
        log "Installed jq, curl, and lm-sensors"
    elif [[ -f /etc/redhat-release ]]; then
        log "RedHat-based OS detected"
        yum install -y epel-release
        yum install -y jq curl lm_sensors
        log "Installed jq, curl, and lm_sensors"
    else
        log "Unsupported OS"
        echo "Unsupported OS"
        exit 1
    fi
}

install_packages

DEFAULT_SERVICES_TO_MONITOR="pve-cluster,pvedaemon,qemu-server,pveproxy"

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

configure_telegram

send_telegram_message() {
    local message="$1"
    local api_url="https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage"
    local data=$(jq -n --arg chat_id "$TELEGRAM_CHAT_ID" --arg text "$message" '{chat_id: $chat_id, text: $text}')

    curl -s -X POST "$api_url" -H "Content-Type: application/json" -d "$data" > /dev/null
    log "Sent message to Telegram: $message"
}

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
            if systemctl is-active --quiet "$service"; then
                send_telegram_message "🟢 [Server $SERVER_ID] Service $service is active."
            else
                send_telegram_message "🔴 [Server $SERVER_ID] Service $service is inactive."
            fi
        done
    fi
}

monitor_vms() {
    local vms=$(qm list | awk 'NR>1 {print $1, $2, $3}')
    local status_changed=false
    local current_status=""
    local previous_status=""

    if [ -f "$VM_STATUS_FILE" ]; then
        previous_status=$(cat "$VM_STATUS_FILE")
    fi

    while read -r vm; do
        local vm_id=$(echo "$vm" | awk '{print $1}')
        local vm_name=$(echo "$vm" | awk '{print $2}')
        local status=$(echo "$vm" | awk '{print $3}')
        current_status+="$vm_id:$status;"

        if [[ ! "$previous_status" =~ "$vm_id:$status;" ]]; then
            status_changed=true
            if [ "$status" == "running" ]; then
                send_telegram_message "🟢 [Server $SERVER_ID] VM $vm_name ($vm_id) is running."
            else
                send_telegram_message "🔴 [Server $SERVER_ID] VM $vm_name ($vm_id) is not running."
            fi
        fi
    done <<< "$vms"

    if $status_changed; then
        echo "$current_status" > "$VM_STATUS_FILE"
    fi
}

monitor_disk() {
    local disk_usage=$(df / | grep / | awk '{print $5}' | sed 's/%//')
    if [ "$disk_usage" -gt $DISK_THRESHOLD ]; then
        send_telegram_message "🔴 [Server $SERVER_ID] Disk usage is above ${DISK_THRESHOLD}%: ${disk_usage}% used."
    fi
}

monitor_cpu() {
    local cpu_load=$(top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - $1}')
    if (( $(echo "$cpu_load > $CPU_THRESHOLD" | bc -l) )); then
        send_telegram_message "🔴 [Server $SERVER_ID] CPU load is above ${CPU_THRESHOLD}%: ${cpu_load}%."
    fi
}

monitor_memory() {
    local mem_usage=$(free | grep Mem | awk '{print $3/$2 * 100.0}')
    if (( $(echo "$mem_usage > $MEM_THRESHOLD" | bc -l) )); then
        send_telegram_message "🔴 [Server $SERVER_ID] Memory usage is above ${MEM_THRESHOLD}%: ${mem_usage}%."
    fi
}

monitor_temperature() {
    local temp=$(sensors | grep 'Package id 0:' | awk '{print $4}' | sed 's/+//;s/°C//')
    if (( $(echo "$temp > $TEMP_THRESHOLD" | bc -l) )); then
        send_telegram_message "🔴 [Server $SERVER_ID] CPU temperature is above ${TEMP_THRESHOLD}°C: ${temp}°C."
    fi
}

monitoring_loop() {
    while true; do
        monitor_services
        monitor_vms
        monitor_disk
        monitor_cpu
        monitor_memory
        monitor_temperature
        sleep 60
    done
}

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

            log "Processing update_id: $update_id, chat_id: $chat_id, message_text: $message_text"

            if [ "$chat_id" == "$TELEGRAM_CHAT_ID" ]; then
                if [ -n "$message_text" ]; then
                    local command=$(echo "$message_text" | awk '{print $1}')
                    local args=$(echo "$message_text" | cut -d' ' -f2-)

                    log "Received command: $command from chat_id: $chat_id"

                    case $command in
                        /server_id)
                            log "Sending server ID: $SERVER_ID"
                            send_telegram_message "Server ID: $SERVER_ID"
                            ;;
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
                            log "Sending help message"
                            send_telegram_message "$help_message"
                            ;;
                        /list_enabled_services)
                            local cmd_server_id=$(echo "$args" | awk '{print $1}')
                            if [ "$cmd_server_id" == "$SERVER_ID" ]; then
                                local services=$(systemctl list-unit-files --type=service --state=enabled --no-pager | awk 'NR>1 {print $1}')
                                for service in $services; do
                                    if systemctl is-active --quiet "$service"; then
                                        send_telegram_message "🟢 [Server $SERVER_ID] $service is active."
                                    else
                                        send_telegram_message "🔴 [Server $SERVER_ID] $service is inactive."
                                    fi
                                done
                            fi
                            ;;
                        /list_vms)
                            local cmd_server_id=$(echo "$args" | awk '{print $1}')
                            if [ "$cmd_server_id" == "$SERVER_ID" ]; then
                                local vms=$(qm list | awk 'NR>1 {print $1, $2, $3}')
                                while read -r vm; do
                                    local vm_id=$(echo "$vm" | awk '{print $1}')
                                    local vm_name=$(echo "$vm" | awk '{print $2}')
                                    local status=$(echo "$vm" | awk '{print $3}')
                                    if [ "$status" == "running" ]; then
                                        send_telegram_message "🟢 [Server $SERVER_ID] $vm_name ($vm_id) is running."
                                    else
                                        send_telegram_message "🔴 [Server $SERVER_ID] $vm_name ($vm_id) is not running."
                                    fi
                                done <<< "$vms"
                            else
                                send_telegram_message "Error: This command is only available for Proxmox servers."
                            fi
                            ;;
                        /status_vm)
                            local cmd_server_id=$(echo "$args" | awk '{print $1}')
                            local vm_id=$(echo "$args" | awk '{print $2}')
                            if [ "$cmd_server_id" == "$SERVER_ID" ]; then
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
                            local cmd_server_id=$(echo "$args" | awk '{print $1}')
                            local vm_id=$(echo "$args" | awk '{print $2}')
                            if [ "$cmd_server_id" == "$SERVER_ID" ]; then
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
                            local cmd_server_id=$(echo "$args" | awk '{print $1}')
                            local vm_id=$(echo "$args" | awk '{print $2}')
                            if [ "$cmd_server_id" == "$SERVER_ID" ]; then
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
                            local cmd_server_id=$(echo "$args" | awk '{print $1}')
                            local vm_id=$(echo "$args" | awk '{print $2}')
                            if [ "$cmd_server_id" == "$SERVER_ID" ]; then
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
                            local cmd_server_id=$(echo "$args" | awk '{print $1}')
                            local service=$(echo "$args" | awk '{print $2}')
                            if [ "$cmd_server_id" == "$SERVER_ID" ]; then
                                if [ -z "$service" ]; then
                                    send_telegram_message "Error: service must be specified."
                                else
                                    local status=$(systemctl status "$service" 2>&1)
                                    send_telegram_message "Status of service $service on server $SERVER_ID:\n$status"
                                fi
                            fi
                            ;;
                        /start_service)
                            local cmd_server_id=$(echo "$args" | awk '{print $1}')
                            local service=$(echo "$args" | awk '{print $2}')
                            if [ "$cmd_server_id" == "$SERVER_ID" ]; then
                                if [ -z "$service" ]; then
                                    send_telegram_message "Error: service must be specified."
                                else
                                    local result=$(systemctl start "$service" 2>&1)
                                    send_telegram_message "Service $service started on server $SERVER_ID.\n$result"
                                fi
                            fi
                            ;;
                        /stop_service)
                            local cmd_server_id=$(echo "$args" | awk '{print $1}')
                            local service=$(echo "$args" | awk '{print $2}')
                            if [ "$cmd_server_id" == "$SERVER_ID" ]; then
                                if [ -z "$service" ]; then
                                    send_telegram_message "Error: service must be specified."
                                else
                                    local result=$(systemctl stop "$service" 2>&1)
                                    send_telegram_message "Service $service stopped on server $SERVER_ID.\n$result"
                                fi
                            fi
                            ;;
                        /restart_service)
                            local cmd_server_id=$(echo "$args" | awk '{print $1}')
                            local service=$(echo "$args" | awk '{print $2}')
                            if [ "$cmd_server_id" == "$SERVER_ID" ]; then
                                if [ -z "$service" ]; then
                                    send_telegram_message "Error: service must be specified."
                                else
                                    local result_stop=$(systemctl stop "$service" 2>&1)
                                    local result_start=$(systemctl start "$service" 2>&1)
                                    send_telegram_message "Service $service restarted on server $SERVER_ID.\nStop result: $result_stop\nStart result: $result_start"
                                fi
                            fi
                            ;;
                        /sudo)
                            local cmd_server_id=$(echo "$args" | awk '{print $1}')
                            local sudo_command=$(echo "$args" | cut -d' ' -f2-)
                            if [ "$cmd_server_id" == "$SERVER_ID" ]; then
                                if [ -z "$sudo_command" ]; then
                                    send_telegram_message "Error: command must be specified."
                                else
                                    local result=$(sudo "$sudo_command" 2>&1)
                                    send_telegram_message "$result"
                                fi
                            fi
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

send_telegram_message "Monitoring script started on server $SERVER_ID."

handle_telegram_commands &
monitoring_loop
