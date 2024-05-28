import json
import requests
import os
import subprocess
import psutil
import time
from telegram import Update, Bot
from telegram.ext import Updater, CommandHandler, CallbackContext

# Конфигурация
CONFIG_PATH = 'config.json'
CHECK_INTERVAL = 60  # Интервал проверки в секундах

def save_config(token, chat_id, server_id):
    config = {
        'token': token,
        'chat_id': chat_id,
        'server_id': server_id
    }
    with open(CONFIG_PATH, 'w') as f:
        json.dump(config, f)

def load_config():
    if os.path.exists(CONFIG_PATH):
        with open(CONFIG_PATH, 'r') as f:
            return json.load(f)
    else:
        raise FileNotFoundError("Configuration file not found. Please run config_setup.py first.")

def send_message(token, chat_id, text):
    url = f'https://api.telegram.org/bot{token}/sendMessage'
    data = {'chat_id': chat_id, 'text': text}
    response = requests.post(url, data=data)
    log_response(response)

def log_response(response):
    with open('telegram_log.json', 'a') as f:
        json.dump(response.json(), f)
        f.write('\n')

def check_service_status(service_name):
    status = os.system(f'systemctl is-active --quiet {service_name}')
    return status == 0

def manage_service(service_name, action):
    os.system(f'systemctl {action} {service_name}')
    return check_service_status(service_name)

def get_vm_list():
    result = subprocess.check_output('qm list', shell=True).decode('utf-8')
    lines = result.strip().split('\n')[1:]  # Пропускаем заголовок
    vms = [line.split()[0] for line in lines]
    return vms

def get_vm_status(vm_id):
    status = subprocess.check_output(f'qm status {vm_id}', shell=True).decode('utf-8').strip()
    return status

def manage_vm(vm_id, action):
    subprocess.call(f'qm {action} {vm_id}', shell=True)
    return get_vm_status(vm_id)

def get_critical_services():
    services = ['pve-cluster', 'pvedaemon', 'pveproxy', 'pvestatd', 'pve-firewall', 'pve-ha-crm', 'pve-ha-lrm', 'pve-ha-manager']
    return services

def ping_server(ip_address):
    response = os.system(f'ping -c 1 {ip_address}')
    return response == 0

def check_disk_usage():
    return psutil.disk_usage('/').percent

def check_cpu_usage():
    return psutil.cpu_percent(interval=1)

def check_memory_usage():
    return psutil.virtual_memory().percent

def start(update: Update, context: CallbackContext):
    update.message.reply_text('Monitoring bot started!')

def handle_command(update: Update, context: CallbackContext):
    config = load_config()
    command = update.message.text.split()
    if len(command) < 3 or command[1] != config['server_id']:
        return

    action = command[0]
    target = command[2]

    if action == "/start_service":
        result = manage_service(target, 'start')
        send_message(config['token'], config['chat_id'], f'Service {target} started: {result}')
    elif action == "/stop_service":
        result = manage_service(target, 'stop')
        send_message(config['token'], config['chat_id'], f'Service {target} stopped: {result}')
    elif action == "/restart_service":
        result = manage_service(target, 'restart')
        send_message(config['token'], config['chat_id'], f'Service {target} restarted: {result}')
    elif action == "/status_service":
        result = check_service_status(target)
        send_message(config['token'], config['chat_id'], f'Service {target} status: {"running" if result else "stopped"}')
    elif action == "/start_vm":
        result = manage_vm(target, 'start')
        send_message(config['token'], config['chat_id'], f'VM {target} started: {result}')
    elif action == "/stop_vm":
        result = manage_vm(target, 'stop')
        send_message(config['token'], config['chat_id'], f'VM {target} stopped: {result}')
    elif action == "/restart_vm":
        result = manage_vm(target, 'reset')
        send_message(config['token'], config['chat_id'], f'VM {target} restarted: {result}')
    elif action == "/status_vm":
        result = get_vm_status(target)
        send_message(config['token'], config['chat_id'], f'VM {target} status: {result}')
    elif action == "/help" and len(command) > 1 and command[1] == config['server_id']:
        send_help_message(config['token'], config['chat_id'])
    else:
        send_message(config['token'], config['chat_id'], 'Unknown command')

def send_help_message(token, chat_id):
    help_text = (
        "Available commands:\n"
        "\n"
        "/start_service <server_id> <service_name> - Start a system service\n"
        "Example: /start_service server1 nginx\n"
        "\n"
        "/stop_service <server_id> <service_name> - Stop a system service\n"
        "Example: /stop_service server1 nginx\n"
        "\n"
        "/restart_service <server_id> <service_name> - Restart a system service\n"
        "Example: /restart_service server1 nginx\n"
        "\n"
        "/status_service <server_id> <service_name> - Check the status of a system service\n"
        "Example: /status_service server1 nginx\n"
        "\n"
        "/start_vm <server_id> <vm_id> - Start a virtual machine\n"
        "Example: /start_vm server1 101\n"
        "\n"
        "/stop_vm <server_id> <vm_id> - Stop a virtual machine\n"
        "Example: /stop_vm server1 101\n"
        "\n"
        "/restart_vm <server_id> <vm_id> - Restart a virtual machine\n"
        "Example: /restart_vm server1 101\n"
        "\n"
        "/status_vm <server_id> <vm_id> - Check the status of a virtual machine\n"
        "Example: /status_vm server1 101\n"
    )
    send_message(token, chat_id, help_text)

def kill_existing_processes(script_name, server_id):
    result = subprocess.check_output(['ps', '-xauf'])
    lines = result.decode('utf-8').split('\n')
    for line in lines:
        if script_name in line and server_id in line:
            parts = line.split()
            pid = int(parts[1])
            if pid != os.getpid():
                os.system(f'kill -9 {pid}')

def monitor_status(config):
    previous_services_status = {}
    previous_vms_status = {}

    while True:
        # Проверка состояния системных сервисов
        services = get_critical_services()
        for service in services:
            current_status = check_service_status(service)
            previous_status = previous_services_status.get(service)
            if previous_status is not None and previous_status != current_status:
                send_message(config['token'], config['chat_id'], f'Service {service} changed status to: {"running" if current_status else "stopped"}')
            previous_services_status[service] = current_status

        # Проверка состояния виртуальных машин
        current_vms = get_vm_list()
        new_vms = set(current_vms) - set(previous_vms_status.keys())
        for vm in new_vms:
            send_message(config['token'], config['chat_id'], f'New VM created: {vm}')
        for vm in current_vms:
            current_status = get_vm_status(vm)
            previous_status = previous_vms_status.get(vm)
            if previous_status is not None and previous_status != current_status:
                send_message(config['token'], config['chat_id'], f'VM {vm} changed status to: {current_status}')
            previous_vms_status[vm] = current_status

        time.sleep(CHECK_INTERVAL)

def main():
    config = load_config()
    script_name = os.path.basename(__file__)
    kill_existing_processes(script_name, config['server_id'])
    
    # Отправка сообщения о старте
    send_message(config['token'], config['chat_id'], f'Monitoring bot started on server {config["server_id"]}!')

    bot = Bot(token=config['token'])
    updater = Updater(bot=bot)
    dp = updater.dispatcher
    dp.add_handler(CommandHandler('start', start))
    dp.add_handler(CommandHandler('command', handle_command))
    dp.add_handler(CommandHandler('help', lambda update, context: send_help_message(config['token'], config['chat_id']) if update.message.text.split()[1] == config['server_id'] else None))
    
    # Запуск мониторинга в фоновом режиме
    updater.start_polling()
    monitor_status(config)
    updater.idle()

if __name__ == '__main__':
    main()
