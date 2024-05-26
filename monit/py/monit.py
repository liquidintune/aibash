import os
import json
import requests
import psutil
import subprocess
import logging
from time import sleep
from typing import List, Dict, Any
from telegram import Bot, Update, InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import CommandHandler, CallbackQueryHandler, Application, ApplicationBuilder, ContextTypes
from telegram.error import BadRequest

# Constants
CONFIG_FILE = 'config.json'
LOG_FILE = 'monitoring.log'

# Setup logging
logging.basicConfig(filename=LOG_FILE, level=logging.INFO,
                    format='%(asctime)s - %(levelname)s - %(message)s')

# Define known services for auto-detection
KNOWN_SERVICES = {
    'FreePBX': ['asterisk'],
    'LNMP': ['nginx', 'php-fpm', 'mysql'],
    'Zimbra': ['zimbra'],
    'Proxmox': ['pve-cluster', 'pveproxy']
}

def load_config() -> Dict[str, Any]:
    """Load or initialize configuration."""
    if os.path.exists(CONFIG_FILE):
        with open(CONFIG_FILE, 'r') as f:
            config = json.load(f)
    else:
        config = {
            'telegram_token': '',
            'chat_id': '',
            'server_id': '',
            'server_type': '',
            'services': [],
            'proxmox': {
                'vm_ids': []
            },
            'remote_servers': []
        }
    
    # Ensure all necessary keys are present
    if 'proxmox' not in config:
        config['proxmox'] = {'vm_ids': []}
    if 'vm_ids' not in config['proxmox']:
        config['proxmox']['vm_ids'] = []
    
    return config

def save_config(config: Dict[str, Any]) -> None:
    """Save configuration to a file."""
    with open(CONFIG_FILE, 'w') as f:
        json.dump(config, f)

def detect_server_type() -> str:
    """Detect server type based on installed services."""
    detected_types = []
    for server_type, services in KNOWN_SERVICES.items():
        if all(subprocess.run(['systemctl', 'is-active', service], stdout=subprocess.PIPE).returncode == 0 for service in services):
            detected_types.append(server_type)
    
    if len(detected_types) == 1:
        return detected_types[0]
    elif len(detected_types) > 1:
        logging.warning(f"Multiple server types detected: {detected_types}. Defaulting to {detected_types[0]}.")
        return detected_types[0]
    else:
        return 'unknown'

def setup_telegram() -> Dict[str, Any]:
    """Setup Telegram bot configuration."""
    config = load_config()
    if not config['telegram_token'] or not config['chat_id'] or not config['server_id'] or not config['server_type']:
        config['telegram_token'] = input('Enter Telegram bot token: ')
        config['chat_id'] = input('Enter chat ID: ')
        config['server_id'] = input('Enter server ID: ')
        detected_type = detect_server_type()
        if detected_type != 'unknown':
            print(f"Detected server type: {detected_type}")
        config['server_type'] = input(f'Enter server type (default: {detected_type}): ') or detected_type
        save_config(config)

    if config['server_type'] == 'proxmox' and not config['proxmox']['vm_ids']:
        config['proxmox']['vm_ids'] = input('Enter Proxmox VM IDs (comma-separated): ').split(',')
        save_config(config)

    logging.info(f"Proxmox Configuration: {config['proxmox']}")
    return config

config = setup_telegram()
bot = Bot(token=config['telegram_token'])

def send_telegram_message(message: str) -> None:
    """Send a message to the configured Telegram chat."""
    try:
        bot.send_message(chat_id=config['chat_id'], text=message)
        logging.info(f"Sent message to Telegram: {message}")
    except BadRequest as e:
        logging.error(f"BadRequest error: {e.message}")
    except Exception as e:
        logging.error(f"Failed to send message to Telegram: {e}")

def check_server_id(update: Update, context: ContextTypes.DEFAULT_TYPE) -> bool:
    """Check if the server ID matches the one in the configuration."""
    if len(context.args) == 0 or context.args[0] != config['server_id']:
        return False
    return True

def monitor_services() -> None:
    """Monitor system services."""
    for service in config['services']:
        try:
            result = subprocess.run(['systemctl', 'is-active', service], stdout=subprocess.PIPE)
            if result.stdout.decode('utf-8').strip() != 'active':
                send_telegram_message(f'Service {service} is down')
                logging.warning(f"Service {service} is down")
        except Exception as e:
            logging.error(f"Error monitoring service {service}: {e}")

def monitor_proxmox_vms() -> None:
    """Monitor Proxmox virtual machines using command line."""
    try:
        for vm_id in config['proxmox']['vm_ids']:
            result = subprocess.run(['qm', 'status', vm_id], stdout=subprocess.PIPE)
            status = result.stdout.decode('utf-8').strip()
            if "status: running" not in status:
                send_telegram_message(f"VM ID {vm_id} is not running")
                logging.warning(f"VM ID {vm_id} is not running")
    except Exception as e:
        logging.error(f"Error monitoring Proxmox VMs: {e}")

def monitor_remote_servers() -> None:
    """Monitor remote servers using ping."""
    for server in config['remote_servers']:
        try:
            result = subprocess.run(['ping', '-c', '1', server], stdout=subprocess.PIPE)
            if result.returncode != 0:
                send_telegram_message(f'Remote server {server} is unreachable')
                logging.warning(f"Remote server {server} is unreachable")
        except Exception as e:
            logging.error(f"Error monitoring remote server {server}: {e}")

def monitor_resources() -> None:
    """Monitor system resources."""
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

async def start(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Handle the /start command."""
    if check_server_id(update, context):
        await update.message.reply_text('Monitoring started.')

async def stop(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Handle the /stop command."""
    if check_server_id(update, context):
        await update.message.reply_text('Monitoring stopped.')

async def status(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Handle the /status command."""
    if check_server_id(update, context):
        await update.message.reply_text('Monitoring status: running')

async def service_status(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Handle the /service_status command."""
    if check_server_id(update, context):
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
            await update.message.reply_text(f"{service}: {status}", reply_markup=reply_markup)

async def vm_status(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Handle the /vm_status command."""
    if check_server_id(update, context):
        vm_status_list = []
        for vm_id in config['proxmox']['vm_ids']:
            result = subprocess.run(['qm', 'status', vm_id], stdout=subprocess.PIPE)
            status = result.stdout.decode('utf-8').strip()
            vm_status_list.append(f"VM ID {vm_id}: {status}")
            buttons = [
                [InlineKeyboardButton("Start", callback_data=f"start_vm:{vm_id}"),
                 InlineKeyboardButton("Stop", callback_data=f"stop_vm:{vm_id}"),
                 InlineKeyboardButton("Restart", callback_data=f"restart_vm:{vm_id}")]
            ]
            reply_markup = InlineKeyboardMarkup(buttons)
            try:
                await update.message.reply_text(f"VM ID {vm_id}: {status}", reply_markup=reply_markup)
            except BadRequest as e:
                logging.error(f"BadRequest error when sending VM status: {e.message}")
        try:
            await update.message.reply_text('\n'.join(vm_status_list))
        except BadRequest as e:
            logging.error(f"BadRequest error when sending VM status list: {e.message}")

async def button_handler(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Handle button presses in Telegram."""
    query = update.callback_query
    await query.answer()
    data = query.data.split(":")
    action = data[0]
    target_type = data[1]
    
    if target_type == "service":
        service_name = data[2]
        if action == "start_service":
            subprocess.run(['systemctl', 'start', service_name])
        elif action == "stop_service":
            subprocess.run(['systemctl', 'stop', service_name])
        elif action == "restart_service":
            subprocess.run(['systemctl', 'restart', service_name])
        await query.edit_message_text(text=f"Service {service_name} action {action} performed.")

    if target_type == "vm":
        vm_id = data[2]
        if action == "start_vm":
            subprocess.run(['qm', 'start', vm_id])
        elif action == "stop_vm":
            subprocess.run(['qm', 'stop', vm_id])
        elif action == "restart_vm":
            subprocess.run(['qm', 'reset', vm_id])
        await query.edit_message_text(text=f"VM ID {vm_id} action {action} performed.")

async def server_id_command(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Handle the /server_id command."""
    await update.message.reply_text(f'Server ID: {config["server_id"]}')

async def help_command(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Handle the /help command."""
    help_text = """
    /start <server_id> - Start monitoring
    /stop <server_id> - Stop monitoring
    /status <server_id> - Get monitoring status
    /service_status <server_id> - Get status of services with control buttons
    /vm_status <server_id> - Get status of VMs with control buttons
    /server_id - Get server ID
    """
    await update.message.reply_text(help_text)

def setup_telegram_commands() -> Application:
    """Setup Telegram bot commands."""
    application = ApplicationBuilder().token(config['telegram_token']).build()

    application.add_handler(CommandHandler('start', start))
    application.add_handler(CommandHandler('stop', stop))
    application.add_handler(CommandHandler('status', status))
    application.add_handler(CommandHandler('service_status', service_status))
    application.add_handler(CommandHandler('vm_status', vm_status))
    application.add_handler(CommandHandler('server_id', server_id_command))
    application.add_handler(CommandHandler('help', help_command))
    application.add_handler(CallbackQueryHandler(button_handler))

    application.run_polling()
    return application

application = setup_telegram_commands()

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
