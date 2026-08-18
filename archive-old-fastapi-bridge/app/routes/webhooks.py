"""
Вебхуки платёжных провайдеров — v4.

Что изменилось относительно v3:
1. `_fulfill_order` теперь выдаёт ключ ПАКЕТОМ на все локации сразу через
   `provisioning.provision_bundle` (см. этот файл — критическая находка по
   реальному backup: одна покупка = ключ на каждом хосте, а не на одном
   выбранном). Раньше здесь искался `order["host_name"]` в `xui_hosts` —
   этого параметра в заказе больше нет (см. routes/orders.py v4).
2. Идемпотентность — без изменений, уже было верно: на уровне БД через
   `processed_webhooks` (INSERT с PRIMARY KEY provider_id) и через
   `app_orders.status` (UPDATE ... WHERE status != 'fulfilled'), а не
   только in-memory проверкой — переживает рестарт процесса и гонку двух
   почти одновременных вебхуков.
3. Не доверяем статусу оплаты из тела запроса — для YooKassa перепроверяем
   через её API по payment_id, для CryptoBot проверяем HMAC-подпись.
"""
import datetime as dt
from fastapi import APIRouter, Request, HTTPException, Header
from app.services import payments, shop_db, provisioning

router = APIRouter()


async def _fulfill_order(order: dict) -> None:
    plans = await shop_db.get_plans()
    plan = next((p for p in plans if p["plan_id"] == order["plan_id"]), None)
    if not plan:
        raise RuntimeError(f"Заказ {order['order_id']} ссылается на несуществующий тариф {order['plan_id']}")

    days = int(plan["months"]) * 30
    identity = order["identity"]
    base_key_email = f"{identity}-{order['order_id'][:8]}"

    await provisioning.provision_bundle(identity, base_key_email, days)


@router.post("/yookassa")
async def yookassa_webhook(request: Request):
    body = await request.json()
    payment_id = body.get("object", {}).get("id")
    if not payment_id:
        raise HTTPException(400, "Нет id платежа в теле запроса")

    if not await shop_db.try_mark_webhook_processed(f"yookassa:{payment_id}"):
        return {"ok": True, "already_processed": True}

    real = await payments.get_yookassa_payment(payment_id)
    if real.get("status") != "succeeded":
        return {"ok": True, "ignored": True}

    order_id = real.get("metadata", {}).get("order_id")
    order = await shop_db.get_order_row(order_id) if order_id else None
    if not order:
        raise HTTPException(404, "Заказ не найден")

    if not await shop_db.mark_order_fulfilled(order_id):
        return {"ok": True, "already_fulfilled": True}

    order["order_id"] = order_id
    await _fulfill_order(order)
    await shop_db.insert_transaction(
        order["identity"], f"yookassa:{payment_id}", "succeeded",
        float(real.get("amount", {}).get("value", 0) or 0), "yookassa",
    )
    return {"ok": True}


@router.post("/cryptobot")
async def cryptobot_webhook(request: Request, crypto_pay_api_signature: str = Header(default="")):
    raw_body = await request.body()
    if not payments.verify_cryptobot_signature(raw_body, crypto_pay_api_signature):
        raise HTTPException(401, "Неверная подпись вебхука")

    body = await request.json()
    order_id = body.get("payload")
    invoice_id = body.get("payload_id") or body.get("invoice_id") or order_id
    if not order_id:
        raise HTTPException(400, "Нет payload (order_id) в теле запроса")

    if not await shop_db.try_mark_webhook_processed(f"cryptobot:{invoice_id}"):
        return {"ok": True, "already_processed": True}

    order = await shop_db.get_order_row(order_id)
    if not order:
        raise HTTPException(404, "Заказ не найден")

    if not await shop_db.mark_order_fulfilled(order_id):
        return {"ok": True, "already_fulfilled": True}

    order["order_id"] = order_id
    await _fulfill_order(order)
    plans = await shop_db.get_plans()
    plan = next((p for p in plans if p["plan_id"] == order["plan_id"]), None)
    await shop_db.insert_transaction(
        order["identity"], f"cryptobot:{invoice_id}", "succeeded",
        float(plan["price"]) if plan else 0.0, "cryptobot",
    )
    return {"ok": True}
