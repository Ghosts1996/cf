"""
Создание и проверка платежей через РЕАЛЬНЫЕ публичные API YooKassa и
CryptoBot (Crypto Pay). Без твоих реальных ключей в .env ничего не
заработает — это правильно, ключи не должны жить в коде.

БЕЗОПАСНОСТЬ (см. routes/webhooks.py для контекста):
- YooKassa не подписывает вебхуки по умолчанию, поэтому нельзя доверять
  статусу из тела запроса — его может прислать кто угодно. Правильная
  практика (реализована ниже): по payment_id из вебхука ЗАПРАШИВАЕМ
  реальный статус напрямую у YooKassa через её API с твоими ключами.
- CryptoBot подписывает вебхук HMAC-SHA256 заголовком
  Crypto-Pay-API-Signature, ключ = SHA256(токен бота). Ниже — проверка
  этой подписи. Без неё вебхук может подделать кто угодно.
"""
import os
import hmac
import hashlib
import httpx

YOOKASSA_SHOP_ID = os.getenv("YOOKASSA_SHOP_ID", "")
YOOKASSA_SECRET_KEY = os.getenv("YOOKASSA_SECRET_KEY", "")
CRYPTOBOT_TOKEN = os.getenv("CRYPTOBOT_TOKEN", "")


async def create_yookassa_payment(amount_rub: float, description: str, order_id: str) -> dict:
    """
    v3 fix: `amount_rub` из твоей реальной таблицы `plans` — тип REAL (float),
    например 290.0. Старое форматирование f"{amount_rub}.00" при float давало
    бы "290.0.00" — YooKassa вернула бы 400 Bad Request на КАЖДОЙ покупке.
    Форматируем через :.2f, что корректно и для float, и для int.
    """
    if not YOOKASSA_SHOP_ID or not YOOKASSA_SECRET_KEY:
        raise RuntimeError("Заполни YOOKASSA_SHOP_ID / YOOKASSA_SECRET_KEY в .env")
    async with httpx.AsyncClient(auth=(YOOKASSA_SHOP_ID, YOOKASSA_SECRET_KEY), timeout=15) as client:
        resp = await client.post(
            "https://api.yookassa.ru/v3/payments",
            headers={"Idempotence-Key": order_id},
            json={
                "amount": {"value": f"{amount_rub:.2f}", "currency": "RUB"},
                "confirmation": {"type": "redirect", "return_url": "https://vpnonline.su/pay/return"},
                "capture": True,
                "description": description,
                "metadata": {"order_id": order_id},
            },
        )
        resp.raise_for_status()
        data = resp.json()
        return {"payment_id": data["id"], "payment_url": data["confirmation"]["confirmation_url"]}


async def get_yookassa_payment(payment_id: str) -> dict:
    """Перепроверка статуса НАПРЯМУЮ у YooKassa — не доверяем данным из вебхука."""
    if not YOOKASSA_SHOP_ID or not YOOKASSA_SECRET_KEY:
        raise RuntimeError("Заполни YOOKASSA_SHOP_ID / YOOKASSA_SECRET_KEY в .env")
    async with httpx.AsyncClient(auth=(YOOKASSA_SHOP_ID, YOOKASSA_SECRET_KEY), timeout=15) as client:
        resp = await client.get(f"https://api.yookassa.ru/v3/payments/{payment_id}")
        resp.raise_for_status()
        return resp.json()


async def create_cryptobot_invoice(amount_rub: float, description: str, order_id: str) -> dict:
    if not CRYPTOBOT_TOKEN:
        raise RuntimeError("Заполни CRYPTOBOT_TOKEN в .env")
    async with httpx.AsyncClient(timeout=15) as client:
        resp = await client.post(
            "https://pay.crypt.bot/api/createInvoice",
            headers={"Crypto-Pay-API-Token": CRYPTOBOT_TOKEN},
            json={
                "amount": f"{amount_rub:.2f}",
                "currency_type": "fiat",
                "fiat": "RUB",
                "description": description,
                "payload": order_id,
            },
        )
        resp.raise_for_status()
        data = resp.json()["result"]
        return {"payment_id": str(data["invoice_id"]), "payment_url": data["pay_url"]}


def verify_cryptobot_signature(body: bytes, signature: str) -> bool:
    """Официальная схема Crypto Pay API: HMAC-SHA256(body), ключ = SHA256(токен)."""
    if not CRYPTOBOT_TOKEN or not signature:
        return False
    secret = hashlib.sha256(CRYPTOBOT_TOKEN.encode()).digest()
    expected = hmac.new(secret, body, hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, signature)
