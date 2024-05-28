import json
import os

CONFIG_PATH = 'config.json'

def save_config(token, chat_id, server_id):
    config = {
        'token': token,
        'chat_id': chat_id,
        'server_id': server_id
    }
    with open(CONFIG_PATH, 'w') as f:
        json.dump(config, f)

def setup_config():
    token = input("Enter your Telegram bot token: ")
    chat_id = input("Enter your Telegram chat ID: ")
    server_id = input("Enter your server ID: ")
    save_config(token, chat_id, server_id)
    print("Configuration saved.")

if __name__ == '__main__':
    setup_config()
