#!/usr/bin/env python3
"""
Записывает платёжные настройки (YooKassa, CryptoBot) в таблицу
bot_settings БД бота.

ВАЖНО: в отличие от SHOPBOT_API_KEY / GMAIL_APP_PASSWORD (они читаются из
переменных окружения — см. ENV_ADDITIONS.env), yookassa_shop_id,
yookassa_secret_key и cryptobot_token читаются функцией get_setting() из
БД (см. database.py -> get_setting() / update_setting(), таблица
bot_settings), а не из .env. Это значит:

  1. Либо у тебя эти значения УЖЕ настроены через админ-панель бота в
     Telegram (тогда этот скрипт просто перезапишет их тем же/новым
     значением — безопасно, INSERT OR REPLACE).
  2. Либо их там ещё нет — тогда без этого шага /billing/topup будет
     отвечать "YooKassa is not configured on the server" /
     "CryptoBot is not configured on the server" (см. api.py, метод
     api_billing_topup).

ПЕРЕД ЗАПУСКОМ: пропиши путь к твоей боевой users.db (там же, где лежит
сам бот на сервере) в переменной DB_PATH ниже, либо передай первым
аргументом: `python3 set_payment_settings.py /root/shopbot/users.db`

Запускать ОДИН РАЗ на сервере, после — можно удалить (значения уже будут
в БД, повторный запуск с теми же данными ничего не сломает, но и не
нужен).

[ИЗМЕНЕНО — критично перед публикацией репозитория] Раньше в SETTINGS
ниже были буквально вписаны твои РЕАЛЬНЫЕ боевые секреты — yookassa_shop_id,
yookassa_secret_key (с префиксом live_, то есть боевой, не тестовый ключ)
и cryptobot_token. Это ровно тот же класс проблемы, что и с
GMAIL_APP_PASSWORD в REPORT.md (п.1): раз значения были один раз записаны
в текст файла, который планируется коммитить в репозиторий (тем более
открытый, см. SECURITY.md/NATIVE_SETUP.md про GPL-3.0), их нужно считать
скомпрометированными, даже если ты вообще не запушишь этот конкретный
коммит — они уже покидали пределы твоего сервера в этом чате.
ОБЯЗАТЕЛЬНО СДЕЛАЙ ПЕРЕД PUSH:
  1. Зайди в личный кабинет YooKassa → перевыпусти secret_key для магазина
     1319024 (старый считай скомпрометированным).
  2. В @CryptoBot → Crypto Pay → My Apps перевыпусти токен приложения
     (старый токен начинался на 561432: — тоже считай скомпрометированным).
  3. Впиши НОВЫЕ значения ниже сам, прямо перед запуском на сервере, и не
     коммить этот файл с заполненными значениями — держи его локально или
     через переменные окружения/аргументы командной строки.
"""
import sqlite3
import sys
from pathlib import Path

DB_PATH = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("users.db")

# [ИЗМЕНЕНО] Вписывай сюда только НОВЫЕ (перевыпущенные) значения — и то
# только локально, непосредственно перед запуском на сервере. Не коммить
# этот файл в git с заполненными значениями.
SETTINGS = {
    "yookassa_shop_id": "ВПИШИ_СЮДА_ЛОКАЛЬНО_ПЕРЕД_ЗАПУСКОМ",
    "yookassa_secret_key": "ВПИШИ_СЮДА_ЛОКАЛЬНО_ПЕРЕД_ЗАПУСКОМ_ПОСЛЕ_ПЕРЕВЫПУСКА",
    "cryptobot_token": "ВПИШИ_СЮДА_ЛОКАЛЬНО_ПЕРЕД_ЗАПУСКОМ_ПОСЛЕ_ПЕРЕВЫПУСКА",
}


def main() -> None:
    if not DB_PATH.exists():
        print(f"Файл БД не найден: {DB_PATH}")
        print("Укажи правильный путь первым аргументом, например:")
        print(f"  python3 {sys.argv[0]} /root/shopbot/users.db")
        sys.exit(1)

    with sqlite3.connect(DB_PATH) as conn:
        cur = conn.cursor()
        cur.execute(
            "CREATE TABLE IF NOT EXISTS bot_settings (key TEXT PRIMARY KEY, value TEXT)"
        )
        for key, value in SETTINGS.items():
            cur.execute(
                "INSERT OR REPLACE INTO bot_settings (key, value) VALUES (?, ?)",
                (key, value),
            )
        conn.commit()

    print(f"Записано в {DB_PATH}:")
    for key in SETTINGS:
        print(f"  - {key}")
    print("\nГотово. Перезапусти бота, чтобы изменения точно применились")
    print("(get_setting читает БД на каждый запрос, перезапуск не строго")
    print("обязателен, но снимает любые сомнения про кеширование).")


if __name__ == "__main__":
    main()
