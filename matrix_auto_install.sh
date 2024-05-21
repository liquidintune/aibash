#!/bin/bash

# Определение переменных
DOMAIN="chat.spkssp.ru"
ELEMENT_PATH="/var/www/element"
ADMIN_PATH="/opt/synapse-admin"
SYNAPSE_CONF_DIR="/etc/matrix-synapse"
SYNAPSE_DATA_DIR="/var/lib/matrix-synapse"
ADMIN_EMAIL="liquid.intune@gmail.com"
TURN_SECRET=$(openssl rand -hex 32)
TURN_USER="turnuser"
TURN_PASSWORD=$(openssl rand -base64 32)
SYNAPSE_SHARED_SECRET=$(openssl rand -hex 32)
CERT_DIR="/etc/letsencrypt/live/${DOMAIN}"
ADMIN_USER="madmin"
ADMIN_PASSWORD=$(openssl rand -base64 32)

# Обновление системы и установка необходимых пакетов
sudo apt update && sudo apt upgrade -y
sudo apt install -y lsb-release wget apt-transport-https gnupg2 curl software-properties-common git nodejs npm python3-venv python3-pip

# Установка Yarn
sudo npm install -g yarn

# Создание пользователя и группы для Synapse
sudo useradd --system --home-dir /var/lib/matrix-synapse --shell /bin/false synapse

# Проверка и удаление предыдущих установок
sudo systemctl stop nginx || true
sudo systemctl stop matrix-synapse || true
sudo systemctl stop coturn || true

# Удаление старой службы systemd, если она существует
sudo rm -f /etc/systemd/system/matrix-synapse.service

# Перезагрузка демона systemd для применения изменений
sudo systemctl daemon-reload

if [ -f "/etc/nginx/sites-enabled/matrix" ]; then
    sudo rm -f /etc/nginx/sites-enabled/matrix
fi

if [ -f "/etc/nginx/sites-available/matrix" ]; then
    sudo rm -f /etc/nginx/sites-available/matrix
fi

if [ -d "${ELEMENT_PATH}" ]; then
    sudo rm -rf ${ELEMENT_PATH}
fi

if [ -d "${ADMIN_PATH}" ]; then
    sudo rm -rf ${ADMIN_PATH}
fi

# Удаление Synapse
if [ -d "${SYNAPSE_CONF_DIR}" ]; then
    sudo rm -rf ${SYNAPSE_CONF_DIR}
fi

if [ -d "${SYNAPSE_DATA_DIR}" ]; then
    sudo rm -rf ${SYNAPSE_DATA_DIR}
fi

# Удаление coturn
if [ -f "/etc/turnserver.conf" ]; then
    sudo rm -f /etc/turnserver.conf
fi

# Добавление репозитория Synapse
wget -qO - https://packages.matrix.org/debian/matrix-org-archive-keyring.gpg | sudo apt-key add -
echo "deb https://packages.matrix.org/debian/ $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/matrix-org.list

# Установка Synapse
sudo apt update
sudo apt install -y matrix-synapse

# Настройка конфигурации Synapse
sudo mkdir -p $SYNAPSE_CONF_DIR
sudo tee $SYNAPSE_CONF_DIR/homeserver.yaml <<EOF
server_name: "${DOMAIN}"
public_baseurl: "https://${DOMAIN}/"

listeners:
  - port: 8008
    type: http
    resources:
      - names: [client, federation]
    tls: false
  - port: 8448
    type: http
    resources:
      - names: [federation]
    tls: true

registration_shared_secret: "${SYNAPSE_SHARED_SECRET}"

enable_registration: true
report_stats: yes

# Enable VoIP
voip:
  turn_uris: ["turn:${DOMAIN}:3478?transport=udp", "turn:${DOMAIN}:3478?transport=tcp"]
  turn_shared_secret: "${TURN_SECRET}"
  turn_user_lifetime: 86400000
  turn_allow_guests: true
EOF

# Создание новой службы systemd для Synapse
sudo tee /etc/systemd/system/matrix-synapse.service <<EOF
[Unit]
Description=Synapse Matrix homeserver
After=network.target

[Service]
Type=simple
User=synapse
Group=synapse
WorkingDirectory=${SYNAPSE_CONF_DIR}
ExecStart=/usr/bin/python3 -m synapse.app.homeserver -c ${SYNAPSE_CONF_DIR}/homeserver.yaml
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# Перезагрузка демона systemd для применения новой службы
sudo systemctl daemon-reload
sudo systemctl enable matrix-synapse
sudo systemctl start matrix-synapse

# Проверка статуса Synapse и вывод логов
sudo systemctl status matrix-synapse
sudo journalctl -u matrix-synapse -n 50

# Ожидание запуска Synapse
echo "Ожидание запуска Synapse..."
until curl -sf http://localhost:8008/_matrix/client/versions; do
    sleep 5
done

# Создание пользователя madmin
sudo register_new_matrix_user -c $SYNAPSE_CONF_DIR/homeserver.yaml -u $ADMIN_USER -p $ADMIN_PASSWORD -a http://localhost:8008

# Установка и настройка Nginx
sudo apt install -y nginx
sudo rm -f /etc/nginx/sites-enabled/default

sudo tee /etc/nginx/sites-available/matrix <<EOF
server {
    listen 80;
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    server_name ${DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;

    location /_matrix {
        proxy_pass http://localhost:8008;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header Host \$host;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }

    location /_matrix/federation/v1 {
        proxy_pass http://localhost:8448;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header Host \$host;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }

    location /element/ {
        alias ${ELEMENT_PATH}/;
        index index.html;
        try_files \$uri \$uri/ /index.html;
    }

    location /admin/ {
        alias ${ADMIN_PATH}/;
        index index.html;
        try_files \$uri \$uri/ /index.html;
    }
}
EOF

sudo ln -sf /etc/nginx/sites-available/matrix /etc/nginx/sites-enabled/matrix

# Установка Certbot и получение SSL сертификата
sudo apt install -y certbot python3-certbot-nginx
sudo mkdir -p /var/www/certbot

# Создание базовой конфигурации Nginx для Certbot
sudo tee /etc/nginx/nginx.conf <<EOF
user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 768;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;

    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
EOF

if [ ! -d "$CERT_DIR" ]; then
    if ! sudo certbot --nginx -d ${DOMAIN} --agree-tos --email ${ADMIN_EMAIL} --non-interactive; then
        sudo certbot --nginx -d ${DOMAIN} --agree-tos --email ${ADMIN_EMAIL} --non-interactive --force-renew
    fi
else
    echo "Сертификаты уже существуют и будут использованы."
fi

# Проверка наличия сертификатов перед перезапуском Nginx
if [ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]; then
    sudo systemctl restart nginx
else
    echo "Ошибка: Сертификаты не найдены."
    exit 1
fi

# Установка и настройка coturn
sudo apt install -y coturn

sudo tee /etc/turnserver.conf <<EOF
listening-port=3478
tls-listening-port=5349
listening-ip=0.0.0.0
relay-ip=0.0.0.0
min-port=49152
max-port=65535
realm=${DOMAIN}
server-name=${DOMAIN}
fingerprint
lt-cred-mech
use-auth-secret
static-auth-secret=${TURN_SECRET}
user=${TURN_USER}:${TURN_PASSWORD}
total-quota=100
bps-capacity=0
stale-nonce
no-loopback-peers
no-multicast-peers
EOF

# Включение и запуск coturn
sudo systemctl enable coturn
sudo systemctl start coturn

# Установка Element
sudo git clone https://github.com/vector-im/element-web.git ${ELEMENT_PATH}
cd ${ELEMENT_PATH}
sudo yarn install
sudo yarn build
sudo chown -R www-data:www-data ${ELEMENT_PATH}

# Установка Synapse Admin
sudo git clone https://github.com/Awesome-Technologies/synapse-admin.git ${ADMIN_PATH}
cd ${ADMIN_PATH}
sudo yarn install
sudo yarn build
sudo chown -R www-data:www-data ${ADMIN_PATH}

sudo ln -sf /etc/nginx/sites-available/synapse-admin /etc/nginx/sites-enabled/synapse-admin

# Перезапуск Nginx
sudo systemctl restart nginx

# Перезапуск Synapse
sudo systemctl restart matrix-synapse

# Вывод сообщения об успешной установке и ключей
echo "Matrix Synapse, coturn, Element и Synapse Admin успешно установлены и настроены на ${DOMAIN}"
echo "Shared secret для Synapse: ${SYNAPSE_SHARED_SECRET}"
echo "TURN сервер пользователь: ${TURN_USER}"
echo "TURN сервер пароль: ${TURN_PASSWORD}"
echo "TURN сервер secret: ${TURN_SECRET}"
echo "Admin пользователь: ${ADMIN_USER}"
echo "Admin пароль: ${ADMIN_PASSWORD}"
