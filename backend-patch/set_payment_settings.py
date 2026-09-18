#!/usr/bin/env python3
"""
Записывает платёжные настройки (YooKassa, CryptoBot) в таблицу bot_settings
БД бота.

В отличие от SHOPBOT_API_KEY и GMAIL_APP_PASSWORD, которые читаются из
переменных окружения (см. ENV_ADDITIONS.env), yookassa_shop_id,
yookassa_secret_key и cryptobot_token берутся get_setting() из БД
(database.py -> get_setting()/update_setting()), а не из .env. Значит:

  1. Либо значения уже настроены через админ-панель бота в Telegram — тогда
     скрипт просто перезапишет их (INSERT OR REPLACE).
  2. Либо их там нет — и тогда /billing/topup отвечает "YooKassa is not
     configured on the server" или "CryptoBot is not configured on the
     server" (api.py, api_billing_topup).

Перед запуском укажите путь к боевой users.db в DB_PATH ниже или передайте
его первым аргументом:

    python3 set_payment_settings.py /root/shopbot/users.db

Запускается один раз на сервере; повторный запуск с теми же данными ничего
не ломает.

Значения в SETTINGS — секреты. Заполняйте их локально непосредственно перед
запуском и не коммитьте файл заполненным: секрет, однажды попавший в
репозиторий, нужно считать скомпрометированным и перевыпускать (YooKassa —
secret_key в личном кабинете магазина, CryptoBot — токен приложения в
@CryptoBot -> Crypto Pay -> My Apps).
"""
import sqlite3
import sys
from pathlib import Path

DB_PATH = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("users.db")

# Заполняется локально перед запуском на сервере; в git этот файл должен
# уходить с плейсхолдерами.
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
