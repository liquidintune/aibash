#!/bin/bash

# Определение переменных
DOMAIN="chat.spkssp.ru"
ELEMENT_PATH="/var/www/element"
ADMIN_PATH="/opt/synapse-admin"
ADMIN_EMAIL="liquid.intune@gmail.com"
TURN_SECRET=$(openssl rand -hex 32)
TURN_USER="turnuser"
TURN_PASSWORD=$(openssl rand -base64 32)
SYNAPSE_SHARED_SECRET=$(openssl rand -hex 32)
CERT_DIR="/etc/letsencrypt/live/${DOMAIN}"
ADMIN_USER="madmin"
ADMIN_PASSWORD=$(openssl rand -base64 32)
DATA_PATH="/opt/matrix"

# Обновление системы и установка необходимых пакетов
sudo apt update && sudo apt upgrade -y
sudo apt install -y lsb-release wget apt-transport-https gnupg2 curl software-properties-common git nodejs npm certbot python3-certbot-nginx

# Установка Docker и Docker Compose
sudo apt install -y docker.io
sudo curl -L "https://github.com/docker/compose/releases/download/1.29.2/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose

# Создание структуры каталогов
sudo mkdir -p $DATA_PATH/synapse
sudo mkdir -p $DATA_PATH/coturn
sudo mkdir -p $ELEMENT_PATH
sudo mkdir -p $ADMIN_PATH

# Создание Docker Compose файла
sudo tee $DATA_PATH/docker-compose.yml <<EOF
version: '3.6'

services:
  synapse:
    image: matrixdotorg/synapse:latest
    container_name: synapse
    volumes:
      - ./synapse:/data
    environment:
      - SYNAPSE_SERVER_NAME=${DOMAIN}
      - SYNAPSE_REPORT_STATS=yes
      - SYNAPSE_REGISTRATION_SHARED_SECRET=${SYNAPSE_SHARED_SECRET}
    ports:
      - 8008:8008
      - 8448:8448
    restart: always

  coturn:
    image: instrumentisto/coturn
    container_name: coturn
    volumes:
      - ./coturn:/etc/coturn
    environment:
      - TURNSERVER_REALM=${DOMAIN}
      - TURNSERVER_LISTEN_IP=0.0.0.0
      - TURNSERVER_EXTERNAL_IP=${DOMAIN}
      - TURNSERVER_PORT=3478
      - TURNSERVER_CERT_FILE=/etc/coturn/ssl/fullchain.pem
      - TURNSERVER_PKEY_FILE=/etc/coturn/ssl/privkey.pem
      - TURNSERVER_STATIC_AUTH_SECRET=${TURN_SECRET}
      - TURNSERVER_RELAY_IP=0.0.0.0
      - TURNSERVER_MIN_PORT=49152
      - TURNSERVER_MAX_PORT=65535
    ports:
      - 3478:3478
      - 3478:3478/udp
    restart: always

  element:
    image: vectorim/element-web
    container_name: element
    volumes:
      - ./element:/app
    ports:
      - 80:80
    restart: always

  synapse-admin:
    image: awesometechnologies/synapse-admin
    container_name: synapse-admin
    ports:
      - 8080:80
    restart: always
EOF

# Запуск Docker Compose
cd $DATA_PATH
sudo docker-compose up -d

# Настройка сертификатов с помощью Certbot
if [ ! -d "$CERT_DIR" ]; then
    if ! sudo certbot --nginx -d ${DOMAIN} --agree-tos --email ${ADMIN_EMAIL} --non-interactive; then
        sudo certbot --nginx -d ${DOMAIN} --agree-tos --email ${ADMIN_EMAIL} --non-interactive --force-renew
    fi
else
    echo "Сертификаты уже существуют и будут использованы."
fi

# Создание пользователя madmin
docker exec -it synapse register_new_matrix_user -c /data/homeserver.yaml -u $ADMIN_USER -p $ADMIN_PASSWORD -a

# Настройка и перезапуск Nginx
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

    location /element/ {
        proxy_pass http://localhost:80;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header Host \$host;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }

    location /admin/ {
        proxy_pass http://localhost:8080;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header Host \$host;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF

sudo ln -sf /etc/nginx/sites-available/matrix /etc/nginx/sites-enabled/matrix
sudo systemctl restart nginx

# Вывод информации
echo "Matrix Synapse, coturn, Element и Synapse Admin успешно установлены и настроены на ${DOMAIN}"
echo "Shared secret для Synapse: ${SYNAPSE_SHARED_SECRET}"
echo "TURN сервер пользователь: ${TURN_USER}"
echo "TURN сервер пароль: ${TURN_PASSWORD}"
echo "TURN сервер secret: ${TURN_SECRET}"
echo "Admin пользователь: ${ADMIN_USER}"
echo "Admin пароль: ${ADMIN_PASSWORD}"
