#!/bin/bash

# Установка зависимостей
sudo apt-get update
sudo apt-get install -y wget curl curl gnupg2 lsb-release

# Добавление GPG ключа репозитория rustdesk
curl -fsSL https://rustdesk-package-server.sc.daftuar.com/rustdesk-archive-keyring.gpg | sudo gpg --dearmor -o /usr/share/keyrings/rustdesk-archive-keyring.gpg

# Добавление репозитория rustdesk
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/rustdesk-archive-keyring.gpg] https://rustdesk-package-server.sc.daftuar.com/debian/ $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/rustdesk.list > /dev/null

# Установка rustdesk
sudo apt-get update
sudo apt-get install -y rustdesk

# Проверка существования файла конфигурации
if [ ! -f ~/.config/rustdesk/client.conf ]; then
    echo "Файл конфигурации не найден. Будет запущен настройщик rustdesk."
    # Запуск настройщика rustdesk
    rustdesk --config

    # Проверка существования файла конфигурации после настройки
    if [ -f ~/.config/rustdesk/client.conf ]; then
        echo "Файл конфигурации успешно создан."
    else
        echo "Не удалось создать файл конфигурации. Выход из приложения."
        exit 1
    fi
fi

# Чтение данных из файла конфигурации
SERVER_IP=$(grep -m 1 'relay-server' ~/.config/rustdesk/client.conf | cut -d '=' -f2)
SERVER_ID=$(grep -m 1 'device-id' ~/.config/rustdesk/client.conf | cut -d '=' -f2)
ACCESS_PASSWORD=$(grep -m 1 'unattended-access-password' ~/.config/rustdesk/client.conf | cut -d '=' -f2)

# Проверка наличия данных в файле конфигурации
if [ -z "$SERVER_IP" ] || [ -z "$SERVER_ID" ] || [ -z "$ACCESS_PASSWORD" ]; then
    echo "Недостаточно данных в файле конфигурации. Будет запущен ввод данных вручную."
    # Ввод данных вручную
    read -p "Введите server_ip: " SERVER_IP
    read -p "Введите server_id: " SERVER_ID
    read -sp "Введите пароль неконтроллируемого доступа: " ACCESS_PASSWORD
    echo

    # Сохранение данных в файл конфигурации
    cat > ~/.config/rustdesk/client.conf << EOL
relay-server = "$SERVER_IP"
device-id = "$SERVER_ID"
unattended-access-password = "$ACCESS_PASSWORD"
EOL

    echo "Данные успешно сохранены в файл конфигурации."
fi

# Отправка сообщения в группу Telegram с помощью бота
BOT_TOKEN="your_bot_token"
CHAT_ID="your_chat_id"

curl -s -X POST https://api.telegram.org/bot$BOT_TOKEN/sendMessage \
-d chat_id=$CHAT_ID \
-d text="Rustdesk client installed with the following parameters:\nserver_ip: $SERVER_IP\nserver_id: $SERVER_ID\nunattended_access_password: *****"

# Запуск rustdesk
rustdesk &
