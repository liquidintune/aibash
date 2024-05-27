import json
import requests
import os
import subprocess
import psutil
from telegram import Update
from telegram.ext import Updater, CommandHandler, CallbackContext

# Конфигурация
CONFIG_PATH = 'config.json'

def save_config(token, chat_id, server_id, server_type):
    config = {
        'token': token,
        'chat_id': chat_id,
        'server_id': server_id,
        'server_type': server_type
    }
    with open(CONFIG_PATH, 'w') as f:
        json.dump(config, f)

def load_config():
    with open(CONFIG_PATH, 'r') as f:
        return json.load(f)

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

def get_vm_status(vm_id):
    status = subprocess.check_output(f'qm status {vm_id}', shell=True)
    return status.strip()

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
    command = update.message.text
    # Обработка команды и выполнение соответствующих действий

def main():
    config = load_config()
    updater = Updater(config['token'])
    dp = updater.dispatcher
    dp.add_handler(CommandHandler('start', start))
    dp.add_handler(CommandHandler('command', handle_command))
    updater.start_polling()
    updater.idle()

if __name__ == '__main__':
    main()
