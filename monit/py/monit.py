import os
import requests
import psutil
import subprocess
import time
import json

LOG_FILE = "/var/log/monitoring_script.log"
CONFIG_FILE = os.path.expanduser("~/.monitoring_config")
SECRET_FILE = os.path.expanduser("~/.monitoring_secret")
STATUS_FILE = "/tmp/monitoring_status"
VM_STATUS_FILE = "/tmp/vm_monitoring_status"
SERVER_STATUS_FILE = "/tmp/remote_server_status"
DISK_THRESHOLD = 10
CPU_THRESHOLD = 90
MEM_THRESHOLD = 92
DEFAULT_SERVICES_TO_MONITOR = ""

def log(message):
    with open(LOG_FILE, "a") as f:
        f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} - {message}\n")

def install_packages():
    if os.path.exists("/etc/debian_version"):
        log("Debian-based OS detected")
        os.system("apt-get update && apt-get install -y jq curl")
        log("Installed jq and curl")
    elif os.path.exists("/etc/redhat-release"):
        log("RedHat-based OS detected")
        os.system("yum install -y epel-release && yum install -y jq curl")
        log("Installed jq and curl")
    else:
        log("Unsupported OS")
        print("Unsupported OS")
        exit(1)

def configure_telegram():
    global DEFAULT_SERVICES_TO_MONITOR
    if not os.path.exists(CONFIG_FILE):
        TELEGRAM_BOT_TOKEN = input("Enter Telegram bot token: ")
        TELEGRAM_CHAT_ID = input("Enter Telegram group chat ID: ")
        SERVER_ID = input("Enter unique server ID: ")
        SERVER_TYPE = input("Enter type of server (proxmox/lnmp/zimbra): ")

        with open(SECRET_FILE, "w") as f:
            f.write(f"TELEGRAM_BOT_TOKEN={TELEGRAM_BOT_TOKEN}\n")
        os.chmod(SECRET_FILE, 0o600)

        with open(CONFIG_FILE, "w") as f:
            f.write(f"TELEGRAM_CHAT_ID={TELEGRAM_CHAT_ID}\n")
            f.write(f"SERVER_ID={SERVER_ID}\n")
            f.write(f"SERVER_TYPE={SERVER_TYPE}\n")
        
        if SERVER_TYPE == "proxmox":
            DEFAULT_SERVICES_TO_MONITOR = "pve-cluster,pvedaemon,qemu-server,pveproxy"
        elif SERVER_TYPE == "lnmp":
            DEFAULT_SERVICES_TO_MONITOR = "nginx,mysql,php-fpm,sshd"
        elif SERVER_TYPE == "zimbra":
            DEFAULT_SERVICES_TO_MONITOR = "zimbra,sshd"
        else:
            print("Unsupported server type")
            exit(1)

        with open(CONFIG_FILE, "a") as f:
            f.write(f"SERVICES_TO_MONITOR={DEFAULT_SERVICES_TO_MONITOR}\n")

        log(f"Configured Telegram bot and saved to {CONFIG_FILE} and {SECRET_FILE}")
    else:
        with open(CONFIG_FILE) as f:
            config = f.read().splitlines()
            for line in config:
                key, value = line.split("=")
                globals()[key] = value
        with open(SECRET_FILE) as f:
            secret = f.read().splitlines()
            for line in secret:
                key, value = line.split("=")
                globals()[key] = value

def send_telegram_message(message):
    api_url = f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/sendMessage"
    data = {
        "chat_id": TELEGRAM_CHAT_ID,
        "text": message
    }
    requests.post(api_url, json=data)
    log(f"Sent message to Telegram: {message}")

def monitor_services():
    services = SERVICES_TO_MONITOR.split(",")
    status_changed = False
    current_status = ""

    for service in services:
        status = subprocess.run(["systemctl", "is-active", service], stdout=subprocess.PIPE, text=True)
        current_status += f"{service}:{status.stdout.strip()};"

    if os.path.exists(STATUS_FILE):
        with open(STATUS_FILE) as f:
            previous_status = f.read()
        if current_status != previous_status:
            status_changed = True
    else:
        status_changed = True

    if status_changed:
        with open(STATUS_FILE, "w") as f:
            f.write(current_status)
        for service in services:
            status = subprocess.run(["systemctl", "is-active", service], stdout=subprocess.PIPE, text=True)
            if status.returncode == 0:
                send_telegram_message(f"🟢 [Server {SERVER_ID}] Service {service} is active.")
            else:
                send_telegram_message(f"🔴 [Server {SERVER_ID}] Service {service} is inactive.")

def monitor_vms():
    if SERVER_TYPE == "proxmox":
        vms = subprocess.run(["qm", "list"], stdout=subprocess.PIPE, text=True).stdout.splitlines()[1:]
        status_changed = False
        current_status = ""
        previous_status = ""

        if os.path.exists(VM_STATUS_FILE):
            with open(VM_STATUS_FILE) as f:
                previous_status = f.read()

        for vm in vms:
            vm_id, vm_name, status = vm.split()[:3]
            current_status += f"{vm_id}:{status};"
            if f"{vm_id}:{status};" not in previous_status:
                status_changed = True
                if status == "running":
                    send_telegram_message(f"🟢 [Server {SERVER_ID}] VM {vm_name} ({vm_id}) is running.")
                else:
                    send_telegram_message(f"🔴 [Server {SERVER_ID}] VM {vm_name} ({vm_id}) is not running.")

        if status_changed:
            with open(VM_STATUS_FILE, "w") as f:
                f.write(current_status)

def monitor_remote_servers():
    if SERVER_TYPE == "proxmox":
        current_status = ""
        status_changed = False

        remote_servers = subprocess.run(["grep", "SERVER_ID=proxmox", "/var/log/remote_servers_status.log"], stdout=subprocess.PIPE, text=True).stdout.splitlines()
        for server in remote_servers:
            server_id = server.split()[1]
            ping_result = subprocess.run(["ping", "-c", "1", server_id], stdout=subprocess.PIPE, text=True).stdout
            if "1 received" in ping_result:
                current_status += f"{server_id}:online;"
            else:
                current_status += f"{server_id}:offline;"

        if os.path.exists(SERVER_STATUS_FILE):
            with open(SERVER_STATUS_FILE) as f:
                previous_status = f.read()
            if current_status != previous_status:
                status_changed = True
        else:
            status_changed = True

        if status_changed:
            with open(SERVER_STATUS_FILE, "w") as f:
                f.write(current_status)
            for server in remote_servers:
                server_id = server.split()[1]
                if f"{server_id}:offline;" in current_status:
                    send_telegram_message(f"🔴 [Server {SERVER_ID}] Remote server {server_id} is offline.")
                else:
                    send_telegram_message(f"🟢 [Server {SERVER_ID}] Remote server {server_id} is online.")

def monitor_disk():
    disk_usage = psutil.disk_usage('/').percent
    if disk_usage >= 100 - DISK_THRESHOLD:
        send_telegram_message(f"🔴 [Server {SERVER_ID}] Disk usage is above {100 - DISK_THRESHOLD}%: {disk_usage}% used.")

def monitor_cpu():
    cpu_load = psutil.cpu_percent(interval=1)
    if cpu_load > CPU_THRESHOLD:
        send_telegram_message(f"🔴 [Server {SERVER_ID}] CPU load is above {CPU_THRESHOLD}%: {cpu_load}%.")

def monitor_memory():
    mem_usage = psutil.virtual_memory().percent
    if mem_usage > MEM_THRESHOLD:
        send_telegram_message(f"🔴 [Server {SERVER_ID}] Memory usage is above {MEM_THRESHOLD}%: {mem_usage}%.")

def monitoring_loop():
    while True:
        monitor_services()
        monitor_vms()
        monitor_disk()
        monitor_cpu()
        monitor_memory()
        monitor_remote_servers()
        time.sleep(60)

def handle_telegram_commands():
    last_update_id = 0

    while True:
        response = requests.get(f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/getUpdates?offset={last_update_id}").json()
        updates = response.get("result", [])

        for update in updates:
            update_id = update["update_id"]
            message = update.get("message", {})
            message_text = message.get("text", "")
            chat_id = message.get("chat", {}).get("id", "")

            log(f"Processing update_id: {update_id}, chat_id: {chat_id}, message_text: {message_text}")

            if chat_id == TELEGRAM_CHAT_ID:
                if message_text:
                    command = message_text.split()[0]
                    args = message_text.split()[1:]

                    log(f"Received command: {command} from chat_id: {chat_id}")

                    if command == "/server_id":
                        log("Sending server ID")
                        send_telegram_message(f"Server ID: {SERVER_ID}")
                    elif command == "/help":
                        help_message = """Available commands:
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
/run <server_id> <command> - Execute a command without sudo privileges."""
                        log("Sending help message")
                        send_telegram_message(help_message)
                    elif command == "/list_enabled_services":
                        if args[0] == SERVER_ID:
                            services = subprocess.run(["systemctl", "list-unit-files", "--type=service", "--state=enabled", "--no-pager"], stdout=subprocess.PIPE, text=True).stdout.splitlines()[1:]
                            for service in services:
                                service_name = service.split()[0]
                                status = subprocess.run(["systemctl", "is-active", service_name], stdout=subprocess.PIPE, text=True)
                                if status.returncode == 0:
                                    send_telegram_message(f"🟢 [Server {SERVER_ID}] {service_name} is active.")
                                else:
                                    send_telegram_message(f"🔴 [Server {SERVER_ID}] {service_name} is inactive.")
                    elif command == "/list_vms":
                        if args[0] == SERVER_ID:
                            vms = subprocess.run(["qm", "list"], stdout=subprocess.PIPE, text=True).stdout.splitlines()[1:]
                            for vm in vms:
                                vm_id, vm_name, status = vm.split()[:3]
                                if status == "running":
                                    send_telegram_message(f"🟢 [Server {SERVER_ID}] {vm_name} ({vm_id}) is running.")
                                else:
                                    send_telegram_message(f"🔴 [Server {SERVER_ID}] {vm_name} ({vm_id}) is not running.")
                        else:
                            send_telegram_message("Error: This command is only available for Proxmox servers.")
                    elif command == "/status_vm":
                        if args[0] == SERVER_ID:
                            if len(args) < 2:
                                send_telegram_message("Error: vm_id must be specified.")
                            else:
                                vm_id = args[1]
                                status = subprocess.run(["qm", "status", vm_id], stdout=subprocess.PIPE, text=True)
                                send_telegram_message(f"Status of VM {vm_id} on server {SERVER_ID}:\n{status.stdout}")
                        else:
                            send_telegram_message("Error: This command is only available for Proxmox servers.")
                    elif command == "/start_vm":
                        if args[0] == SERVER_ID:
                            if len(args) < 2:
                                send_telegram_message("Error: vm_id must be specified.")
                            else:
                                vm_id = args[1]
                                result = subprocess.run(["qm", "start", vm_id], stdout=subprocess.PIPE, text=True)
                                send_telegram_message(f"VM {vm_id} started on server {SERVER_ID}.\n{result.stdout}")
                        else:
                            send_telegram_message("Error: This command is only available for Proxmox servers.")
                    elif command == "/stop_vm":
                        if args[0] == SERVER_ID:
                            if len(args) < 2:
                                send_telegram_message("Error: vm_id must be specified.")
                            else:
                                vm_id = args[1]
                                result = subprocess.run(["qm", "stop", vm_id], stdout=subprocess.PIPE, text=True)
                                send_telegram_message(f"VM {vm_id} stopped on server {SERVER_ID}.\n{result.stdout}")
                        else:
                            send_telegram_message("Error: This command is only available for Proxmox servers.")
                    elif command == "/restart_vm":
                        if args[0] == SERVER_ID:
                            if len(args) < 2:
                                send_telegram_message("Error: vm_id must be specified.")
                            else:
                                vm_id = args[1]
                                result_stop = subprocess.run(["qm", "stop", vm_id], stdout=subprocess.PIPE, text=True)
                                result_start = subprocess.run(["qm", "start", vm_id], stdout=subprocess.PIPE, text=True)
                                send_telegram_message(f"VM {vm_id} restarted on server {SERVER_ID}.\nStop result: {result_stop.stdout}\nStart result: {result_start.stdout}")
                        else:
                            send_telegram_message("Error: This command is only available for Proxmox servers.")
                    elif command == "/status_service":
                        if args[0] == SERVER_ID:
                            if len(args) < 2:
                                send_telegram_message("Error: service must be specified.")
                            else:
                                service = args[1]
                                status = subprocess.run(["systemctl", "status", service], stdout=subprocess.PIPE, text=True)
                                send_telegram_message(f"Status of service {service} on server {SERVER_ID}:\n{status.stdout}")
                    elif command == "/start_service":
                        if args[0] == SERVER_ID:
                            if len(args) < 2:
                                send_telegram_message("Error: service must be specified.")
                            else:
                                service = args[1]
                                result = subprocess.run(["systemctl", "start", service], stdout=subprocess.PIPE, text=True)
                                send_telegram_message(f"Service {service} started on server {SERVER_ID}.\n{result.stdout}")
                    elif command == "/stop_service":
                        if args[0] == SERVER_ID:
                            if len(args) < 2:
                                send_telegram_message("Error: service must be specified.")
                            else:
                                service = args[1]
                                result = subprocess.run(["systemctl", "stop", service], stdout=subprocess.PIPE, text=True)
                                send_telegram_message(f"Service {service} stopped on server {SERVER_ID}.\n{result.stdout}")
                    elif command == "/restart_service":
                        if args[0] == SERVER_ID:
                            if len(args) < 2:
                                send_telegram_message("Error: service must be specified.")
                            else:
                                service = args[1]
                                result_stop = subprocess.run(["systemctl", "stop", service], stdout=subprocess.PIPE, text=True)
                                result_start = subprocess.run(["systemctl", "start", service], stdout=subprocess.PIPE, text=True)
                                send_telegram_message(f"Service {service} restarted on server {SERVER_ID}.\nStop result: {result_stop.stdout}\nStart result: {result_start.stdout}")
                    elif command == "/run":
                        if args[0] == SERVER_ID:
                            command_to_run = " ".join(args[1:])
                            if not command_to_run:
                                send_telegram_message("Error: command must be specified.")
                            else:
                                result = subprocess.run(command_to_run, shell=True, stdout=subprocess.PIPE, text=True)
                                send_telegram_message(result.stdout)
                    else:
                        send_telegram_message(f"Unknown command: {message_text}")

            last_update_id = update_id + 1

        time.sleep(5)

def install_service():
    service_file = f"""
[Unit]
Description=Monitoring Service

[Service]
ExecStart={os.path.abspath(__file__)}
Restart=always
User={os.getlogin()}

[Install]
WantedBy=multi-user.target
"""
    with open("/etc/systemd/system/monitoring.service", "w") as f:
        f.write(service_file)

    os.system("systemctl daemon-reload")
    os.system("systemctl enable monitoring.service")
    os.system("systemctl start monitoring.service")

send_telegram_message("Monitoring script started on server {SERVER_ID}.")

install_packages()
configure_telegram()
install_service()
handle_telegram_commands()
monitoring_loop()
