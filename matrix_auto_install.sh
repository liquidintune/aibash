#!/bin/bash

# Определение переменных
DOMAIN="chat.spkssp.ru"
SYNAPSE_CONF_DIR="/etc/matrix-synapse"
SYNAPSE_DATA_DIR="/var/lib/matrix-synapse"
ADMIN_EMAIL="liquid.intune@gmail.com"
TURN_SECRET=$(openssl rand -hex 32)
TURN_USER="turnuser"
TURN_PASSWORD=$(openssl rand -base64 32)
SYNAPSE_SHARED_SECRET=$(openssl rand -hex 32)

# Обновление системы и установка необходимых пакетов
apt update && apt upgrade -y
apt install -y lsb-release wget apt-transport-https gnupg2 curl software-properties-common

# Добавление репозитория Synapse
wget -qO - https://packages.matrix.org/debian/matrix-org-archive-keyring.gpg | apt-key add -
echo "deb https://packages.matrix.org/debian/ $(lsb_release -cs) main" > /etc/apt/sources.list.d/matrix-org.list

# Установка Synapse
apt update
apt install -y matrix-synapse-py3

# Настройка конфигурации Synapse
cat > $SYNAPSE_CONF_DIR/homeserver.yaml <<EOF
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

# Установка и настройка Nginx
apt install -y nginx
cat > /etc/nginx/sites-available/matrix <<EOF
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
}

server {
    listen 80;
    server_name element.${DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    server_name element.${DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;

    root /var/www/element;
    index index.html;
}
EOF

ln -s /etc/nginx/sites-available/matrix /etc/nginx/sites-enabled/matrix
rm /etc/nginx/sites-enabled/default

# Установка Certbot и получение SSL сертификата
apt install -y certbot python3-certbot-nginx
mkdir -p /var/www/certbot

if ! certbot certonly --webroot --webroot-path /var/www/certbot -d ${DOMAIN} -d element.${DOMAIN} --agree-tos --email ${ADMIN_EMAIL} --non-interactive; then
    certbot certonly --webroot --webroot-path /var/www/certbot -d ${DOMAIN} -d element.${DOMAIN} --agree-tos --email ${ADMIN_EMAIL} --non-interactive --force-renew
fi

# Перезапуск Nginx для применения нового сертификата
systemctl restart nginx

# Установка и настройка coturn
apt install -y coturn

cat > /etc/turnserver.conf <<EOF
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
systemctl enable coturn
systemctl start coturn

# Установка Element
apt install -y unzip
wget -O /tmp/element.zip https://github.com/vector-im/element-web/releases/download/v1.9.0/element-v1.9.0.zip
unzip /tmp/element.zip -d /var/www/element

# Установка Synapse Admin
mkdir -p /opt/synapse-admin
wget -O /opt/synapse-admin/synapse-admin.zip https://github.com/Awesome-Technologies/synapse-admin/releases/download/v0.8.0/synapse-admin-v0.8.0.zip
unzip /opt/synapse-admin/synapse-admin.zip -d /opt/synapse-admin
cat > /etc/nginx/sites-available/synapse-admin <<EOF
server {
    listen 80;
    server_name admin.${DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    server_name admin.${DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;

    root /opt/synapse-admin;
    index index.html;
}
EOF

ln -s /etc/nginx/sites-available/synapse-admin /etc/nginx/sites-enabled/synapse-admin

# Перезапуск Nginx
systemctl restart nginx

# Запуск Synapse
systemctl enable matrix-synapse
systemctl start matrix-synapse

# Вывод сообщения об успешной установке и ключей
echo "Matrix Synapse, coturn, Element и Synapse Admin успешно установлены и настроены на ${DOMAIN}"
echo "Shared secret для Synapse: ${SYNAPSE_SHARED_SECRET}"
echo "TURN сервер пользователь: ${TURN_USER}"
echo "TURN сервер пароль: ${TURN_PASSWORD}"
echo "TURN сервер secret: ${TURN_SECRET}"
