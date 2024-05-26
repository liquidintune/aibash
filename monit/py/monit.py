import os
import json
import requests
import psutil
import subprocess
import logging
from time import sleep
from telegram import Bot, Update, InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import CommandHandler, CallbackQueryHandler, Updater
from proxmoxer import ProxmoxAPI

# Constants
CONFIG_FILE = 'config.json'
LOG_FILE = 'monitoring.log'

# Setup logging
logging.basicConfig(filename=LOG_FILE, level=logging.INFO,
                    format='%(asctime)s - %(levelname)s - %(message)s')

# Load or initialize configuration
def load_config():
    if os.path.exists(CONFIG_FILE):
        with open(CONFIG_FILE, 'r') as f:
            return json.load(f)
    else:
        return {
            'telegram_token': '',
            'chat_id': '',
            'server_id': '',
            'server_type': '',
            'services': [],
            'proxmox': {
                'host': '',
                'username': '',
                'password': ''
            },
            'remote_servers': []
        }

def save_config(config):
    with open(CONFIG_FILE, 'w') as f:
        json.dump(config, f)

# Telegram setup
def setup_telegram():
    config = load_config()
    if not config['telegram_token'] or not config['chat_id'] or not config['server_id'] or not config['server_type']:
        config['telegram_token'] = input('Enter Telegram bot token: ')
        config['chat_id'] = input('Enter chat ID: ')
        config['server_id'] = input('Enter server ID: ')
        config['server_type'] = input('Enter server type: ')
        save_config(config)
    return config

config = setup_telegram()
bot = Bot(token=config['telegram_token'])

def send_telegram_message(message):
    try:
        bot.send_message(chat_id=config['chat_id'], text=message)
        logging.info(f"Sent message to Telegram: {message}")
    except Exception as e:
        logging.error(f"Failed to send message to Telegram: {e}")

def check_server_id(context):
    if len(context.args) == 0 or context.args[0] != config['server_id']:
        return False
    return True

# Monitor system services
def monitor_services():
    for service in config['services']:
        try:
            result = subprocess.run(['systemctl', 'is-active', service], stdout=subprocess.PIPE)
            if result.stdout.decode('utf-8').strip() != 'active':
                send_telegram_message(f'Service {service} is down')
                logging.warning(f"Service {service} is down")
        except Exception as e:
            logging.error(f"Error monitoring service {service}: {e}")

# Monitor Proxmox VMs
def monitor_proxmox_vms():
    try:
        proxmox = ProxmoxAPI(config['proxmox']['host'], user=config['proxmox']['username'], password=config['proxmox']['password'], verify_ssl=False)
        for node in proxmox.nodes.get():
            for vm in proxmox.nodes(node['node']).qemu.get():
                vm_status = proxmox.nodes(node['node']).qemu(vm['vmid']).status.current.get()
                if vm_status['status'] != 'running':
                    send_telegram_message(f"VM {vm['name']} (ID {vm['vmid']}) is not running")
                    logging.warning(f"VM {vm['name']} (ID {vm['vmid']}) is not running")
    except Exception as e:
        logging.error(f"Error monitoring Proxmox VMs: {e}")

# Monitor remote servers
def monitor_remote_servers():
    for server in config['remote_servers']:
        try:
            result = subprocess.run(['ping', '-c', '1', server], stdout=subprocess.PIPE)
            if result.returncode != 0:
                send_telegram_message(f'Remote server {server} is unreachable')
                logging.warning(f"Remote server {server} is unreachable")
        except Exception as e:
            logging.error(f"Error monitoring remote server {server}: {e}")

# Monitor system resources
def monitor_resources():
    try:
        disk_usage = psutil.disk_usage('/')
        if disk_usage.percent > 90:
            send_telegram_message(f'Disk usage is at {disk_usage.percent}%')
            logging.warning(f"Disk usage is at {disk_usage.percent}%")
        
        memory_usage = psutil.virtual_memory()
        if memory_usage.percent > 90:
            send_telegram_message(f'Memory usage is at {memory_usage.percent}%')
            logging.warning(f"Memory usage is at {memory_usage.percent}%")
        
        cpu_usage = psutil.cpu_percent(interval=1)
        if cpu_usage > 90:
            send_telegram_message(f'CPU usage is at {cpu_usage}%')
            logging.warning(f"CPU usage is at {cpu_usage}%")
    except Exception as e:
        logging.error(f"Error monitoring system resources: {e}")

# Handle Telegram commands
def start(update, context):
    if check_server_id(context):
        update.message.reply_text('Monitoring started.')

def stop(update, context):
    if check_server_id(context):
        update.message.reply_text('Monitoring stopped.')

def status(update, context):
    if check_server_id(context):
        update.message.reply_text('Monitoring status: running')

def service_status(update, context):
    if check_server_id(context):
        services_status = []
        for service in config['services']:
            result = subprocess.run(['systemctl', 'is-active', service], stdout=subprocess.PIPE)
            status = result.stdout.decode('utf-8').strip()
            services_status.append(f"{service}: {status}")
            buttons = [
                [InlineKeyboardButton("Start", callback_data=f"start_service:{service}"),
                 InlineKeyboardButton("Stop", callback_data=f"stop_service:{service}"),
                 InlineKeyboardButton("Restart", callback_data=f"restart_service:{service}")]
            ]
            reply_markup = InlineKeyboardMarkup(buttons)
            update.message.reply_text(f"{service}: {status}", reply_markup=reply_markup)

def vm_status(update, context):
    if check_server_id(context):
        try:
            proxmox = ProxmoxAPI(config['proxmox']['host'], user=config['proxmox']['username'], password=config['proxmox']['password'], verify_ssl=False)
            vms_status = []
            for node in proxmox.nodes.get():
                for vm in proxmox.nodes(node['node']).qemu.get():
                    vm_status = proxmox.nodes(node['node']).qemu(vm['vmid']).status.current.get()
                    vms_status.append(f"VM {vm['name']} (ID {vm['vmid']}): {vm_status['status']}")
                    buttons = [
                        [InlineKeyboardButton("Start", callback_data=f"start_vm:{node['node']}:{vm['vmid']}"),
                         InlineKeyboardButton("Stop", callback_data=f"stop_vm:{node['node']}:{vm['vmid']}"),
                         InlineKeyboardButton("Restart", callback_data=f"restart_vm:{node['node']}:{vm['vmid']}")]
                    ]
                    reply_markup = InlineKeyboardMarkup(buttons)
                    update.message.reply_text(f"VM {vm['name']} (ID {vm['vmid']}): {vm_status['status']}", reply_markup=reply_markup)
        except Exception as e:
            logging.error(f"Error fetching VM status: {e}")
            update.message.reply_text(f"Error fetching VM status: {e}")

def button_handler(update, context):
    query = update.callback_query
    query.answer()
    data = query.data.split(":")
    action = data[0]
    target_type = data[1]
    
    if target_type == "service":
        service_name = data[1]
        if action == "start_service":
            subprocess.run(['systemctl', 'start', service_name])
        elif action == "stop_service":
            subprocess.run(['systemctl', 'stop', service_name])
        elif action == "restart_service":
            subprocess.run(['systemctl', 'restart', service_name])
        query.edit_message_text(text=f"Service {service_name} action {action} performed.")

    if target_type == "vm":
        node = data[2]
        vmid = data[3]
        proxmox = ProxmoxAPI(config['proxmox']['host'], user=config['proxmox']['username'], password=config['proxmox']['password'], verify_ssl=False)
        if action == "start_vm":
            proxmox.nodes(node).qemu(vmid).status.start.post()
        elif action == "stop_vm":
            proxmox.nodes(node).qemu(vmid).status.stop.post()
        elif action == "restart_vm":
            proxmox.nodes(node).qemu(vmid).status.reboot.post()
        query.edit_message_text(text=f"VM ID {vmid} action {action} performed.")

def server_id_command(update, context):
    update.message.reply_text(f'Server ID: {config["server_id"]}')

def help_command(update, context):
    help_text = """
    /start <server_id> - Start monitoring
    /stop <server_id> - Stop monitoring
    /status <server_id> - Get monitoring status
    /service_status <server_id> - Get status of services with control buttons
    /vm_status <server_id> - Get status of VMs with control buttons
    /server_id - Get server ID
    """
    update.message.reply_text(help_text)

def setup_telegram_commands():
    updater = Updater(token=config['telegram_token'], use_context=True)
    dispatcher = updater.dispatcher
    dispatcher.add_handler(CommandHandler('start', start, pass_args=True))
    dispatcher.add_handler(CommandHandler('stop', stop, pass_args=True))
    dispatcher.add_handler(CommandHandler('status', status, pass_args=True))
    dispatcher.add_handler(CommandHandler('service_status', service_status, pass_args=True))
    dispatcher.add_handler(CommandHandler('vm_status', vm_status, pass_args=True))
    dispatcher.add_handler(CommandHandler('server_id', server_id_command))
    dispatcher.add_handler(CommandHandler('help', help_command))
    dispatcher.add_handler(CallbackQueryHandler(button_handler))
    updater.start_polling()
    return updater

updater = setup_telegram_commands()

# Main monitoring loop
while True:
    if config['server_type'] == 'service':
        monitor_services()
    elif config['server_type'] == 'proxmox':
        monitor_proxmox_vms()
    elif config['server_type'] == 'remote':
        monitor_remote_servers()
    elif config['server_type'] in ['FreePBX', 'LNMP', 'Zimbra']:
        monitor_services()
    
    monitor_resources()
    sleep(60)
