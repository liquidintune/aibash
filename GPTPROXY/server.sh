#!/bin/bash

API_KEY="ваш_api_ключ"
DEFAULT_MODEL="gpt-4"  # Укажите модель по умолчанию
PORT=8080
PROXY_URL="http://your_proxy_address:your_proxy_port"  # Замените на ваш прокси-сервер

# Функция для обработки запросов
handle_request() {
    local QUESTION=$1
    local MODEL=${2:-$DEFAULT_MODEL}
    local DATE=$(date +"%Y%m%d_%H%M%S")
    local FILENAME="tgmonv2_${DATE}.sh"
    local HISTORY_FILE="chat_history.json"

    # Инициализация истории сообщений, если файл не существует
    if [ ! -f "$HISTORY_FILE" ]; then
        echo '[]' > "$HISTORY_FILE"
    fi

    # Обновление истории сообщений
    local HISTORY=$(jq -c --arg question "$QUESTION" '. + [{"role": "user", "content": $question}]' "$HISTORY_FILE")

    # Отправка запроса к API OpenAI через прокси
    local RESPONSE=$(curl -s --proxy "$PROXY_URL" https://api.openai.com/v1/chat/completions \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer $API_KEY" \
      -d '{
      "model": "'$MODEL'",
      "messages": '"$HISTORY"',
      "temperature": 0.7,
      "max_tokens": 150,
      "n": 1,
      "stop": null
    }')

    # Извлечение кода из ответа
    local CODE=$(echo $RESPONSE | jq -r '.choices[0].message.content' | sed -n '/```bash/,/```/p' | sed '/```/d')

    # Обновление истории сообщений с ответом
    local ANSWER=$(echo $RESPONSE | jq -r '.choices[0].message.content')
    HISTORY=$(echo $HISTORY | jq -c --arg answer "$ANSWER" '. + [{"role": "assistant", "content": $answer}]')
    echo $HISTORY > "$HISTORY_FILE"

    # Возврат извлеченного кода
    if [ -n "$CODE" ]; then
        echo "$CODE"
    else
        echo "Не удалось извлечь код из ответа."
    fi
}

# Запуск netcat для прослушивания порта
while true; do
    { 
        # Прочитать строку запроса
        read -r request

        # Извлечение вопроса и модели из запроса
        QUESTION=$(echo "$request" | cut -d'|' -f1)
        MODEL=$(echo "$request" | cut -d'|' -f2)

        # Обработка запроса и отправка ответа
        RESPONSE=$(handle_request "$QUESTION" "$MODEL")
        echo -e "HTTP/1.1 200 OK\r\nContent-Length: ${#RESPONSE}\r\n\r\n$RESPONSE"
    } | nc -l -p $PORT -q 1
done
