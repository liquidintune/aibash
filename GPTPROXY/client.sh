#!/bin/bash

# Проверка наличия jq
if ! command -v jq &> /dev/null
then
    echo "jq не установлен. Установите jq и попробуйте снова."
    exit 1
fi

# Проверка наличия аргументов
if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    echo "Использование: $0 \"ваш вопрос\" [модель]"
    exit 1
fi

QUESTION=$1
MODEL=${2:-"gpt-4"}  # Укажите модель по умолчанию
PROXY_SERVER="your_proxy_server_ip:8080"  # Замените на адрес вашего прокси-сервера

# Файл истории сообщений
HISTORY_FILE="chat_history.json"

# Инициализация истории сообщений, если файл не существует
if [ ! -f "$HISTORY_FILE" ]; then
    echo '[]' > "$HISTORY_FILE"
fi

# Обновление истории сообщений новым вопросом
HISTORY=$(jq -c --arg question "$QUESTION" '. + [{"role": "user", "content": $question}]' "$HISTORY_FILE")

# Формирование запроса
REQUEST="${QUESTION}|${MODEL}"

# Отправка запроса к прокси-серверу и получение ответа
RESPONSE=$(echo "$REQUEST" | nc -q 1 "$PROXY_SERVER")

# Извлечение кода из ответа
CODE=$(echo "$RESPONSE" | jq -r '.')

# Обновление истории сообщений с ответом
ANSWER="$RESPONSE"
HISTORY=$(echo $HISTORY | jq -c --arg answer "$ANSWER" '. + [{"role": "assistant", "content": $answer}]')
echo $HISTORY > "$HISTORY_FILE"

# Сохранение кода в файл
if [ -n "$CODE" ]; then
    DATE=$(date +"%Y%m%d_%H%M%S")
    FILENAME="tgmonv2_${DATE}.sh"
    echo "$CODE" > "$FILENAME"
    echo "Код сохранен в $FILENAME"
else
    echo "Не удалось извлечь код из ответа."
fi
