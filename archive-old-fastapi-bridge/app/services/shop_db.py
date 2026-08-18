"""
Доступ к базе данных, которую УЖЕ использует Telegram-бот (форк 3xui-shopbot).

v3: раньше здесь были ПРЕДПОЛОЖЕНИЯ об именах таблиц (users.id, keys, users.referral_code).
Ты прислал реальный backup БД (users-20260803-134623.db) — я разобрал схему по факту,
и предположения оказались частично неверны. Ниже — SQL под РЕАЛЬНУЮ схему:

    users(telegram_id PK, username, total_spent, total_months, trial_used,
          agreed_to_terms, registration_date, is_banned, balance, referred_by,
          referral_balance, referral_balance_all, referral_start_bonus_received,
          max_devices, email, password_hash)

    vpn_keys(key_id PK, user_id -> users.telegram_id, host_name -> xui_hosts.host_name,
             xui_client_uuid, key_email, expiry_date, created_date, device_number,
             parent_key_id, devices_limit)

    xui_hosts(host_name PK, host_url, host_username, host_pass, host_inbound_id,
              subscription_url, ssh_host, ssh_port, ssh_user, ssh_password, ssh_key_path)

    plans(plan_id PK, host_name, plan_name, months, price)

    transactions(transaction_id PK, payment_id, user_id, status, amount_rub,
                 amount_currency, currency_name, payment_method, metadata, created_date)

    host_speedtests(id PK, host_name, method, ping_ms, jitter_ms, download_mbps,
                     upload_mbps, server_name, server_id, ok, error, created_at)

    processed_webhooks(provider_id PK, created_at)

ВАЖНЫЕ РАСХОЖДЕНИЯ С ПРЕДЫДУЩЕЙ ВЕРСИЕЙ (что было неверно и что чинит v3):
1. У users НЕТ отдельного `id` — первичный ключ САМ `telegram_id`. Старый JOIN
   "u.id = k.user_id" был бы гарантированной ошибкой SQL ("no such column: u.id").
2. Таблица ключей называется `vpn_keys`, не `keys`; поля — `host_name` (не
   `inbound_id`!) и `xui_client_uuid` (не `client_uuid`).
3. `host_name` — это ссылка на КОНКРЕТНУЮ панель 3x-ui в таблице `xui_hosts`
   (их у тебя физически 6 разных хостов с разными URL/логином/паролем/inbound_id).
   Старая версия работала с одной панелью через .env — она физически не может
   показать ключи/сервера с остальных 5 хостов. Это главный баг, который чинит v3.
4. Реферальная система у тебя УЖЕ построена на telegram_id, а не на отдельном
   коде: `referred_by` хранит telegram_id пригласившего, а бонусы уже считаются
   в `referral_balance` / `referral_balance_all` / `referral_start_bonus_received`.
   Значит "придумывать" отдельный referral_code и решать размер бонуса не нужно —
   нужно просто читать то, что уже считает бот.
5. Тарифы (`plans`) уже есть в БД, и они per-host (у разных хостов могут быть
   разные тарифы/цены) и в МЕСЯЦАХ, не в днях — старая версия хардкодила тарифы
   в днях в коде бэкенда, что расходилось бы с тем, что видит бот.

БЕЗОПАСНОСТЬ: все запросы — параметризованные (SQLAlchemy text() с bind-параметрами).
Никакой склейки пользовательского ввода в SQL-строку.
"""
import os
import time
from datetime import datetime, timezone

from sqlalchemy.ext.asyncio import create_async_engine, AsyncSession
from sqlalchemy.orm import sessionmaker
from sqlalchemy import text

DATABASE_URL = os.getenv("DATABASE_URL", "")

_engine = None
_Session = None


def _session_factory():
    global _engine, _Session
    if _engine is None:
        if not DATABASE_URL:
            raise RuntimeError(
                "Заполни DATABASE_URL в .env — это ТА ЖЕ БД, что использует бот "
                "(например sqlite+aiosqlite:////root/bot/users.db)."
            )
        _engine = create_async_engine(DATABASE_URL, pool_pre_ping=True)
        _Session = sessionmaker(_engine, class_=AsyncSession, expire_on_commit=False)
    return _Session


def _identity_clause() -> str:
    # identity из JWT — это telegram_id (числом, как строка) или email.
    return "(users.telegram_id = :uid OR users.email = :uid)"


# ---------------------------------------------------------------- users/balance

async def get_user_balance(identity: str) -> dict:
    """Возвращает и обычный, и реферальный баланс — оба показывает бот."""
    Session = _session_factory()
    async with Session() as session:
        result = await session.execute(
            text(
                f"SELECT balance, referral_balance, referral_balance_all "
                f"FROM users WHERE {_identity_clause()} LIMIT 1"
            ),
            {"uid": identity},
        )
        row = result.first()
        if not row:
            return {"balance_rub": 0, "referral_balance_rub": 0, "referral_balance_all_rub": 0}
        return {
            "balance_rub": float(row[0] or 0),
            "referral_balance_rub": float(row[1] or 0),
            "referral_balance_all_rub": float(row[2] or 0),
        }


async def get_user_row(identity: str) -> dict | None:
    Session = _session_factory()
    async with Session() as session:
        result = await session.execute(
            text(
                f"SELECT telegram_id, username, email, max_devices, is_banned, trial_used "
                f"FROM users WHERE {_identity_clause()} LIMIT 1"
            ),
            {"uid": identity},
        )
        row = result.first()
        return dict(row._mapping) if row else None


# ---------------------------------------------------------------- keys

async def get_user_key_rows(identity: str) -> list[dict]:
    """
    Ключи пользователя со ВСЕХ хостов (панелей) сразу — раньше запрос не мог
    вернуть больше одного хоста, потому что вообще не знал о таблице xui_hosts.
    """
    Session = _session_factory()
    async with Session() as session:
        result = await session.execute(
            text(
                f"""
                SELECT vk.key_id, vk.host_name, vk.xui_client_uuid, vk.key_email,
                       vk.expiry_date, vk.created_date, vk.device_number,
                       vk.parent_key_id, vk.devices_limit,
                       xh.host_url, xh.host_inbound_id, xh.subscription_url
                FROM vpn_keys vk
                JOIN users ON users.telegram_id = vk.user_id
                LEFT JOIN xui_hosts xh ON xh.host_name = vk.host_name
                WHERE {_identity_clause()}
                ORDER BY vk.expiry_date DESC
                """
            ),
            {"uid": identity},
        )
        return [dict(r._mapping) for r in result.fetchall()]


async def insert_key_row(
    identity: str, host_name: str, xui_client_uuid: str, key_email: str,
    expiry_date: datetime, devices_limit: int = 3,
) -> int:
    Session = _session_factory()
    async with Session() as session:
        user_row = await session.execute(
            text(f"SELECT telegram_id FROM users WHERE {_identity_clause()} LIMIT 1"),
            {"uid": identity},
        )
        user_id = user_row.scalar()
        if user_id is None:
            raise ValueError(f"Пользователь {identity!r} не найден в users")
        result = await session.execute(
            text(
                """
                INSERT INTO vpn_keys (user_id, host_name, xui_client_uuid, key_email,
                                       expiry_date, devices_limit, device_number)
                VALUES (:user_id, :host_name, :uuid, :key_email, :expiry, :limit, 1)
                """
            ),
            {
                "user_id": user_id, "host_name": host_name, "uuid": xui_client_uuid,
                "key_email": key_email, "expiry": expiry_date, "limit": devices_limit,
            },
        )
        await session.commit()
        return result.lastrowid


async def update_key_expiry(key_id: int, expiry_date: datetime) -> None:
    Session = _session_factory()
    async with Session() as session:
        await session.execute(
            text("UPDATE vpn_keys SET expiry_date = :expiry WHERE key_id = :key_id"),
            {"expiry": expiry_date, "key_id": key_id},
        )
        await session.commit()


# ---------------------------------------------------------------- hosts / servers

async def get_xui_hosts() -> list[dict]:
    """Все панели 3x-ui, привязанные к сервису (это и есть список стран/локаций)."""
    Session = _session_factory()
    async with Session() as session:
        result = await session.execute(
            text(
                "SELECT host_name, host_url, host_username, host_pass, "
                "host_inbound_id, subscription_url FROM xui_hosts"
            )
        )
        return [dict(r._mapping) for r in result.fetchall()]


async def get_latest_speedtests() -> dict[str, dict]:
    """
    Последний замер пинга/скорости по каждому хосту — бот уже это меряет
    (таблица host_speedtests). Используем готовые данные вместо повторного
    измерения с бэкенда, чтобы не плодить лишнюю нагрузку/трафик.
    """
    Session = _session_factory()
    async with Session() as session:
        result = await session.execute(
            text(
                """
                SELECT h.host_name, h.ping_ms, h.jitter_ms, h.download_mbps,
                       h.upload_mbps, h.ok, h.created_at
                FROM host_speedtests h
                INNER JOIN (
                    SELECT host_name, MAX(created_at) AS max_created
                    FROM host_speedtests
                    GROUP BY host_name
                ) latest
                ON latest.host_name = h.host_name AND latest.max_created = h.created_at
                """
            )
        )
        return {row.host_name: dict(row._mapping) for row in result.fetchall()}


# ---------------------------------------------------------------- plans (real, per-host)

async def get_plans() -> list[dict]:
    Session = _session_factory()
    async with Session() as session:
        result = await session.execute(
            text("SELECT plan_id, host_name, plan_name, months, price FROM plans ORDER BY months")
        )
        return [dict(r._mapping) for r in result.fetchall()]


# ---------------------------------------------------------------- trial

async def has_used_trial(identity: str) -> bool:
    Session = _session_factory()
    async with Session() as session:
        result = await session.execute(
            text(f"SELECT trial_used FROM users WHERE {_identity_clause()} LIMIT 1"),
            {"uid": identity},
        )
        row = result.first()
        return bool(row[0]) if row else False


async def mark_trial_used(identity: str) -> None:
    Session = _session_factory()
    async with Session() as session:
        await session.execute(
            text(f"UPDATE users SET trial_used = 1 WHERE {_identity_clause()}"),
            {"uid": identity},
        )
        await session.commit()


# ---------------------------------------------------------------- referral (REAL schema: telegram_id based)

async def get_referral_info(identity: str) -> dict:
    """
    В реальной схеме нет отдельного referral_code — приглашение работает через
    telegram_id (t.me/bot?start=ref_<telegram_id>), а бонусы уже копятся ботом
    в referral_balance / referral_balance_all. Это не изобретается заново —
    просто читается то, что уже есть.
    """
    Session = _session_factory()
    async with Session() as session:
        result = await session.execute(
            text(
                f"SELECT telegram_id, referral_balance, referral_balance_all "
                f"FROM users WHERE {_identity_clause()} LIMIT 1"
            ),
            {"uid": identity},
        )
        row = result.first()
        if not row:
            return {"telegram_id": None, "invited_count": 0, "referral_balance_rub": 0, "referral_balance_all_rub": 0}
        telegram_id = row[0]
        count_row = await session.execute(
            text("SELECT COUNT(*) FROM users WHERE referred_by = :tid"),
            {"tid": telegram_id},
        )
        return {
            "telegram_id": telegram_id,
            "invited_count": int(count_row.scalar() or 0),
            "referral_balance_rub": float(row[1] or 0),
            "referral_balance_all_rub": float(row[2] or 0),
        }


# ---------------------------------------------------------------- orders (durable — v3 fix)
# БАГ, который был раньше: заказы (orders.py) жили только в dict в памяти
# процесса — рестарт бэкенда (деплой/падение) = все "pending" заказы теряются
# безвозвратно, а повторный вебхук от платёжного провайдера после рестарта не
# находит заказ и просто выдаёт 404, деньги улетают в никуда без выдачи ключа.
# Ниже — своя таблица `app_orders` (создаётся автоматически при старте), плюс
# использование уже существующей у бота `processed_webhooks` для железной
# идемпотентности на уровне БД (а не только in-memory проверки статуса).

_ORDERS_TABLE_READY = False


async def _ensure_orders_table(session) -> None:
    global _ORDERS_TABLE_READY
    if _ORDERS_TABLE_READY:
        return
    await session.execute(
        text(
            """
            CREATE TABLE IF NOT EXISTS app_orders (
                order_id TEXT PRIMARY KEY,
                identity TEXT NOT NULL,
                plan_id INTEGER NOT NULL,
                host_name TEXT NOT NULL,
                payment_method TEXT,
                provider_payment_id TEXT,
                status TEXT NOT NULL DEFAULT 'pending',
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
            """
        )
    )
    await session.commit()
    _ORDERS_TABLE_READY = True


async def create_order_row(order_id: str, identity: str, plan_id: int, host_name: str,
                            payment_method: str | None, status: str = "pending") -> None:
    Session = _session_factory()
    async with Session() as session:
        await _ensure_orders_table(session)
        await session.execute(
            text(
                """
                INSERT INTO app_orders (order_id, identity, plan_id, host_name, payment_method, status)
                VALUES (:order_id, :identity, :plan_id, :host_name, :method, :status)
                """
            ),
            {"order_id": order_id, "identity": identity, "plan_id": plan_id,
             "host_name": host_name, "method": payment_method, "status": status},
        )
        await session.commit()


async def set_order_provider_payment_id(order_id: str, provider_payment_id: str) -> None:
    Session = _session_factory()
    async with Session() as session:
        await _ensure_orders_table(session)
        await session.execute(
            text("UPDATE app_orders SET provider_payment_id = :ppid WHERE order_id = :oid"),
            {"ppid": provider_payment_id, "oid": order_id},
        )
        await session.commit()


async def get_order_row(order_id: str) -> dict | None:
    Session = _session_factory()
    async with Session() as session:
        await _ensure_orders_table(session)
        result = await session.execute(
            text("SELECT * FROM app_orders WHERE order_id = :oid"), {"oid": order_id}
        )
        row = result.first()
        return dict(row._mapping) if row else None


async def get_order_by_provider_payment_id(provider_payment_id: str) -> dict | None:
    Session = _session_factory()
    async with Session() as session:
        await _ensure_orders_table(session)
        result = await session.execute(
            text("SELECT * FROM app_orders WHERE provider_payment_id = :ppid"),
            {"ppid": provider_payment_id},
        )
        row = result.first()
        return dict(row._mapping) if row else None


async def mark_order_fulfilled(order_id: str) -> bool:
    """Атомарно помечает заказ выполненным. Возвращает False, если он уже был
    fulfilled (защита от повторной выдачи ключа при повторной доставке вебхука)."""
    Session = _session_factory()
    async with Session() as session:
        await _ensure_orders_table(session)
        result = await session.execute(
            text(
                "UPDATE app_orders SET status = 'fulfilled' "
                "WHERE order_id = :oid AND status != 'fulfilled'"
            ),
            {"oid": order_id},
        )
        await session.commit()
        return result.rowcount > 0


async def try_mark_webhook_processed(provider_id: str) -> bool:
    """
    Использует существующую у бота таблицу processed_webhooks как источник
    истины на уровне БД (переживает рестарт бэкенда, в отличие от
    in-memory проверки). Возвращает False, если этот provider_id уже
    обрабатывался — значит это повтор доставки, ключ второй раз не выдаём.
    """
    Session = _session_factory()
    async with Session() as session:
        try:
            await session.execute(
                text("INSERT INTO processed_webhooks (provider_id) VALUES (:pid)"),
                {"pid": provider_id},
            )
            await session.commit()
            return True
        except Exception:
            await session.rollback()
            return False


# ---------------------------------------------------------------- transactions (visibility for bot/site)

# ---------------------------------------------------------------- public settings (bot_settings)
# v4 FINDING (проверено по реальному backup, не предположение): бесплатный
# триал и проценты реферальной программы НЕ хранятся в plans/users как
# отдельные "изобретённые" поля — они реально живут в таблице bot_settings
# (ключи trial_enabled/trial_duration_days/referral_percentage/
# referral_discount/referral_on_start_referrer_amount/minimum_withdrawal).
# Раньше (v3) экран "Бесплатный период" в приложении писал пользователю,
# что триал "не настроен" — это было НЕВЕРНО: триал включён
# (trial_enabled=true, 2 дня), просто прошлая версия не знала, где его искать.
# Секретные ключи (токены ботов, пароли панелей, ключи платёжных систем)
# сюда сознательно НЕ включены — этот геттер предназначен только для
# публичных, безопасных для показа в приложении значений.
_PUBLIC_SETTINGS_KEYS = (
    "trial_enabled", "trial_duration_days",
    "referral_percentage", "referral_discount", "referral_on_start_referrer_amount",
    "referral_reward_type", "enable_referrals",
    "minimum_withdrawal",
)


async def get_public_settings() -> dict:
    Session = _session_factory()
    async with Session() as session:
        result = await session.execute(text("SELECT key, value FROM bot_settings"))
        raw = {row[0]: row[1] for row in result.fetchall()}

    def _bool(v: str | None) -> bool:
        return str(v).strip().lower() in ("1", "true", "yes", "on")

    def _num(v: str | None, default: float = 0) -> float:
        try:
            return float(v)
        except (TypeError, ValueError):
            return default

    out = {}
    for key in _PUBLIC_SETTINGS_KEYS:
        if key not in raw:
            continue
        if key in ("trial_enabled", "enable_referrals"):
            out[key] = _bool(raw[key])
        elif key in ("trial_duration_days",):
            out[key] = int(_num(raw[key], 0))
        elif key == "referral_reward_type":
            out[key] = raw[key]
        else:
            out[key] = _num(raw[key], 0)
    return out


# ---------------------------------------------------------------- web/app accounts (email+password)
# v4: сайт (vpnonline.su) уже поддерживает регистрацию по email+паролю —
# проверено напрямую на сайте ("Email адрес" / "Пароль" / "Создать аккаунт").
# Пароли хранятся как bcrypt-хэш в users.password_hash (подтверждено по
# формату реальных хэшей в backup: "$2b$10$..."). У аккаунтов, созданных
# ТОЛЬКО через сайт/приложение (без Telegram), telegram_id — ОТРИЦАТЕЛЬНОЕ
# число (подтверждено по backup: реальные строки от -100009 до -100030,
# тогда как настоящие Telegram ID у тебя в базе — большие положительные,
# от 202672835 до 8980983080). Это те же синтетические ID, что уже
# использует твой текущий сайт — не изобретено заново, а установлено по
# факту данных.
async def get_user_by_email(email: str) -> dict | None:
    Session = _session_factory()
    async with Session() as session:
        result = await session.execute(
            text(
                "SELECT telegram_id, username, email, password_hash, is_banned "
                "FROM users WHERE email = :email LIMIT 1"
            ),
            {"email": email},
        )
        row = result.first()
        return dict(row._mapping) if row else None


async def create_web_user(email: str, username: str | None, password_hash: str) -> int:
    """
    Создаёт нового пользователя, зарегистрированного ТОЛЬКО через
    сайт/приложение (без Telegram) — с синтетическим отрицательным
    telegram_id, как это уже делает текущий сайт (см. комментарий выше).
    Retry на конфликт PRIMARY KEY — на случай гонки двух одновременных
    регистраций (redundant по IP rate-limit в auth.py, но не полагаемся
    только на него: это защита на уровне БД).
    """
    Session = _session_factory()
    async with Session() as session:
        for _ in range(5):
            min_id_row = await session.execute(text("SELECT MIN(telegram_id) FROM users"))
            min_id = min_id_row.scalar()
            candidate = min(int(min_id or -100000), -100000) - 1
            try:
                await session.execute(
                    text(
                        """
                        INSERT INTO users (telegram_id, username, email, password_hash,
                                            agreed_to_terms, registration_date)
                        VALUES (:tid, :username, :email, :pwhash, 1, CURRENT_TIMESTAMP)
                        """
                    ),
                    {"tid": candidate, "username": username, "email": email, "pwhash": password_hash},
                )
                await session.commit()
                return candidate
            except Exception:
                await session.rollback()
                continue
    raise RuntimeError("Не удалось выделить свободный telegram_id для нового веб-аккаунта (5 попыток)")


async def update_password_hash(identity: str, new_password_hash: str) -> None:
    Session = _session_factory()
    async with Session() as session:
        await session.execute(
            text(f"UPDATE users SET password_hash = :h WHERE {_identity_clause()}"),
            {"h": new_password_hash, "uid": identity},
        )
        await session.commit()


async def insert_transaction(identity: str, payment_id: str, status: str, amount_rub: float,
                              payment_method: str, metadata: str | None = None) -> None:
    """
    Пишет покупку через приложение в ту же таблицу `transactions`, что видит
    бот и сайт — иначе покупки из приложения были бы "невидимы" в истории
    операций бота, хотя баланс/ключ были бы синхронны. Это и есть последний
    штрих полной синхронизации, которую просил пользователь.
    """
    Session = _session_factory()
    async with Session() as session:
        user_row = await session.execute(
            text(f"SELECT telegram_id, username FROM users WHERE {_identity_clause()} LIMIT 1"),
            {"uid": identity},
        )
        row = user_row.first()
        user_id = row[0] if row else None
        username = row[1] if row else None
        await session.execute(
            text(
                """
                INSERT INTO transactions (username, payment_id, user_id, status, amount_rub,
                                           payment_method, metadata)
                VALUES (:username, :payment_id, :user_id, :status, :amount_rub, :method, :metadata)
                """
            ),
            {
                "username": username, "payment_id": payment_id, "user_id": user_id,
                "status": status, "amount_rub": amount_rub, "method": payment_method,
                "metadata": metadata,
            },
        )
        await session.commit()
