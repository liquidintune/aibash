#!/bin/bash

set -e

# Function to determine OS and install required packages
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

# Function to determine server type
determine_server_type() {
  if dpkg -l | grep -q pve-manager; then
    echo "Proxmox"
  else
    echo "LNMP"
  fi
}

# Install packages
install_packages

# Determine server type and set default services to monitor
SERVER_TYPE=$(determine_server_type)
DEFAULT_SERVICES_TO_MONITOR="pve-cluster,pvedaemon,qemu-server,pveproxy"  # Adjust for LNMP if needed
if [ "$SERVER_TYPE" == "Proxmox" ]; then
  SERVICES_TO_MONITOR="$DEFAULT_SERVICES_TO_MONITOR"
else
  SERVICES_TO_MONITOR="nginx,mysql,php7.4-fpm"  # Adjust for your specific services
fi

# Read configuration from user (if not already present)
if [ ! -f ~/.telegram_bot_config ]; then
  read -p "Enter Telegram bot token: " TELEGRAM_BOT_TOKEN
  read -p "Enter Telegram group chat ID: " TELEGRAM_CHAT_ID
  read -p "Enter unique server ID: " SERVER_ID
  echo "TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN" > ~/.telegram_bot_config
  echo "TELEGRAM_CHAT_ID=$TELEGRAM_CHAT_ID" >> ~/.telegram_bot_config
  echo "SERVER_ID=$SERVER_ID" >> ~/.telegram_bot_config
  echo "SERVICES_TO_MONITOR=$SERVICES_TO_MONITOR" >> ~/.telegram_bot_config
else
  source ~/.telegram_bot_config
fi

# Declare associative arrays (dictionaries) for storing previous statuses
declare -A previous_service_statuses
declare -A previous_vm_statuses

# Function to send Telegram messages
send_telegram_message() {
  local message="$1"
  local buttons="$2"
  local response

  while true; do
    if [ -z "<span class="math-inline">buttons" \]; then
response\=</span>(curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
        -d chat_id="$TELEGRAM_CHAT_ID" \
        -d text="<span class="math-inline">message"\)
else
response\=</span>(curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
        -d chat_id="$TELEGRAM_CHAT_ID" \
        -d text="$message" \
        -d reply_markup="<span class="math-inline">buttons"\)
fi
local ok\=</span>(echo "$response" | jq '.ok')
    if [ "<span class="math-inline">ok" \=\= "true" \]; then
break
else
retry\_after\=</span>(echo "$response" | jq '.parameters.retry_after')
      if [ -n "$retry_after" ] && [ "$retry_after" != "null" ]; then
        sleep "<span class="math-inline">retry\_after"
else
sleep 1
fi
fi
done
\}
\# Function to monitor systemd services
monitor\_services\(\) \{
local services\=\(</span>(echo "<span class="math-inline">SERVICES\_TO\_MONITOR" \| tr ',' ' '\)\)
for service in "</span>{services[@]}"; do
    local current_status=$(systemctl is-active "$service")
    if [[ "$previous_service_statuses[$service]" != "$current_status" ]]; then
      previous_service_statuses[$service]="$current_status"
      if [ "$current_status" != "active" ]; then
        send_telegram_message "Service $service is not running on server $SERVER_ID!"
      fi
    fi
  done
}

# Function to monitor virtual machines (for Proxmox)
monitor_vms() {
  if [ "$SERVER_TYPE" != "Proxmox"
  local vms=$(qm list | awk 'NR>1 {print $1, $2, <span class="math-inline">3\}'\)
while read \-r vm; do
local vm\_id\=</span>(echo $vm | awk '{print <span class="math-inline">1\}'\)
local vm\_name\=</span>(echo $vm | awk '{print <span class="math-inline">2\}'\)
local status\=</span>(echo $vm | awk '{print $3}')

    if [[ "$previous_vm_statuses[$vm_id]" != "$status" ]]; then
      previous_vm_statuses[$vm_id]=$status
      if [ "<span class="math-inline">status" \!\= "running" \]; then
local inline\_keyboard\=</span>(cat <<EOF
{
  "inline_keyboard": [
    [
      {"text": "Status", "callback_data": "/status_vm $SERVER_ID $vm_id"},
      {"text": "Start", "callback_data": "/start_vm $SERVER_ID $vm_id"},
      {"text": "Stop", "callback_data": "/stop_vm $SERVER_ID $vm_id"},
      {"text": "Restart", "callback_data": "/restart_vm $SERVER_ID <span class="math-inline">vm\_id"\}
\]
\]
\}
EOF
\)
local buttons\=</span>(echo $inline_keyboard | jq -c .)
        send_telegram_message "$vm_name ($vm_id) - $status" "$buttons"
      fi
    fi
  done <<< "$vms"
}

# Main monitoring loop
monitoring_loop() {
  while true; do
    monitor_services
    if [ "<span class="math-inline">SERVER\_TYPE" \=\= "Proxmox" \]; then
monitor\_vms
fi
sleep 60
done
\}
\# Function to handle Telegram commands
handle\_telegram\_commands\(\) \{
local last\_update\_id\=0
while true; do
local response\=</span>(curl -s "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/getUpdates?offset=<span class="math-inline">last\_update\_id"\)
local updates\=</span>(echo $response | jq '.result')

    for row in $(echo "$updates" | jq -r '.[] | @base64'); do
      _jq() {
        echo <span class="math-inline">\{row\} \| base64 \-\-decode \| jq \-r '\{1\}'
\}
local update\_id\=</span>(_jq '.update_id')
      local message_text=<span class="math-inline">\(\_jq '\.message\.text'\)
local callback\_query\_id\=</span>(_jq '.callback_query.id')
      local callback_data=<span class="math-inline">\(\_jq '\.callback\_query\.data'\)
local chat\_id\=</span>(_jq '.message.chat.id')
      local message_id=<span class="math-inline">\(\_jq '\.callback\_query\.message\.message\_id'\)
local from\_id\=</span>(_jq '.callback_query.from.id')

      if [ "$chat_id" == "<span class="math-inline">TELEGRAM\_CHAT\_ID" \]; then
local command\=</span>(echo $message_text | awk '{print <span class="math-inline">1\}'\)
local cmd\_server\_id\=</span>(echo $message_text | awk '{print <span class="math-inline">2\}'\)
local args\=</span>(echo $message_text | cut -d' ' -f3-)

        if [ "$command" == "/server_id" ]; then
          send_telegram_message "Server ID: $SERVER_ID"
        elif [ "<span class="math-inline">command" \=\= "/help" \]; then
local help\_message\=</span>(cat <<EOF
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
          case <span class="math-inline">command in
/list\_enabled\_services\)
local enabled\_services\=</span>(systemctl list-unit-files --type=service --state=enabled)
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
              /stop_vm)
                local vm_id=$callback_args
                qm stop $vm_id
                curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/answerCallbackQuery" \
                  -d callback_query_id="$callback_query_id" \
                  -d text="VM $vm_id stopped."
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

        last_update_id=$((update_id + 1))
      done

      sleep 5
    done
  }
}

# Launch Telegram command handling and monitoring
handle_telegram_commands &
monitoring_loop
