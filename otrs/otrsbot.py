from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import Updater, CommandHandler, CallbackContext, CallbackQueryHandler, ConversationHandler, MessageHandler, Filters
from otrs.client import GenericTicketConnector, Session, Ticket, Article

# Определение состояний для ConversationHandler
USERNAME, PASSWORD, TICKET_SUBJECT, TICKET_BODY = range(4)

# Новый URL и путь к OTRS API
OTRS_URL = "https://support.emerhelp.ru/otrs/nph-genericinterface.pl/Webservice/GenericTicketConnector"
OTRS_USER = "liquid"  # Замените на ваше имя пользователя, если требуется
OTRS_PASSWORD = "Kutregopla4200"  # Замените на ваш пароль, если требуется
TELEGRAM_BOT_TOKEN = "your-telegram-bot-token"

# Создание пустой сессии OTRS
session = Session()

def start(update: Update, context: CallbackContext) -> int:
    keyboard = [
        [InlineKeyboardButton("Open", callback_data='open_tickets')],
        [InlineKeyboardButton("New Ticket", callback_data='new_ticket')]
    ]
    reply_markup = InlineKeyboardMarkup(keyboard)
    update.message.reply_text('Выберите действие:', reply_markup=reply_markup)
    return USERNAME

def new_ticket(update: Update, context: CallbackContext) -> int:
    query = update.callback_query
    query.answer()
    query.edit_message_text('Введите тему обращения:')
    return TICKET_SUBJECT

def ticket_subject(update: Update, context: CallbackContext) -> int:
    subject = update.message.text
    context.user_data['ticket_subject'] = subject
    update.message.reply_text('Введите тело сообщения:')
    return TICKET_BODY

def ticket_body(update: Update, context: CallbackContext) -> int:
    body = update.message.text
    subject = context.user_data['ticket_subject']
    otrs_client = GenericTicketConnector(context.user_data['session'])

    # Создание заявки
    ticket = Ticket(Title=subject, Queue='YourQueueName', State='new', Priority='3 normal')
    article = Article(Subject=subject, Body=body, ContentType="text/plain; charset=utf8")
    ticket_id = otrs_client.ticket_create(ticket, article)

    update.message.reply_text(f'Заявка создана. Номер заявки: {ticket_id}')
    return ConversationHandler.END

def main() -> None:
    updater = Updater(TELEGRAM_BOT_TOKEN, use_context=True)
    dispatcher = updater.dispatcher

    conv_handler = ConversationHandler(
        entry_points=[CommandHandler('start', start)],
        states={
            USERNAME: [MessageHandler(Filters.text & ~Filters.command, input_username)],
            PASSWORD: [MessageHandler(Filters.text & ~Filters.command, input_password)],
            TICKET_SUBJECT: [MessageHandler(Filters.text & ~Filters.command, ticket_subject)],
            TICKET_BODY: [MessageHandler(Filters.text & ~Filters.command, ticket_body)]
        },
        fallbacks=[CommandHandler('start', start)]
    )

    dispatcher.add_handler(conv_handler)
    dispatcher.add_handler(CallbackQueryHandler(new_ticket, pattern='^new_ticket$'))
    dispatcher.add_handler(CallbackQueryHandler(get_tickets, pattern='^open_tickets$'))

    updater.start_polling()
    updater.idle()

if __name__ == '__main__':
    main()
