"""
Создание заказа на покупку/продление ключа — v4.

ЧТО ИЗМЕНИЛОСЬ И ПОЧЕМУ (относительно v3):

1. `host_name` БОЛЬШЕ НЕ параметр запроса. Раньше клиент был обязан
   выбрать один сервер на экране "Серверы" перед покупкой — это не
   совпадает с тем, как реально работает сервис: сайт прямо пишет "Единый
   VPN ключ включает в себя доступ сразу к 4 высокоскоростным локациям...
   с автоматической балансировкой", а реальные строки vpn_keys в backup
   подтверждают это (см. routes/keys.py и services/provisioning.py) — одна
   покупка = ключ сразу на КАЖДОМ подключённом хосте, а не на одном.
   Экран "Серверы" остаётся, но становится информационным (пинг/статус),
   а не шагом, обязательным для покупки.

2. Бесплатный триал — ПЕРЕДЕЛАНО. В v3 триал ошибочно считался тарифом с
   price==0 в таблице `plans` — такой строки в реальной БД НЕТ (все 4
   тарифа платные: 50/120/290/480 ₽). Проверено по факту: реальный триал
   настраивается через bot_settings (`trial_enabled`, `trial_duration_days`
   — сейчас true/2 дня) и вообще не имеет отношения к таблице plans.
   Теперь эндпоинт `/v1/orders/trial` активирует именно его.

3. Цена и срок тарифа по-прежнему ВСЕГДА берутся сервером из таблицы
   `plans` по plan_id — клиент передаёт только plan_id, не сумму и не
   количество дней (без изменений относительно v3, это было верно).
"""
import uuid
from fastapi import APIRouter, HTTPException, Depends
from pydantic import BaseModel
from app.services import payments, shop_db, provisioning
from app.auth_deps import get_current_user

router = APIRouter()


class CreateOrderIn(BaseModel):
    plan_id: int
    payment_method: str  # yookassa | cryptobot


async def _get_plan(plan_id: int) -> dict:
    plans = await shop_db.get_plans()
    plan = next((p for p in plans if p["plan_id"] == plan_id), None)
    if not plan:
        raise HTTPException(400, "Неизвестный тариф")
    return plan


@router.post("/trial")
async def create_trial_order(user: dict = Depends(get_current_user)):
    settings = await shop_db.get_public_settings()
    if not settings.get("trial_enabled", False):
        raise HTTPException(409, "Бесплатный пробный период сейчас не включён")
    if await shop_db.has_used_trial(user["sub"]):
        raise HTTPException(409, "Бесплатный тариф уже был использован на этом аккаунте")

    days = int(settings.get("trial_duration_days", 0) or 0)
    if days <= 0:
        raise HTTPException(409, "Бесплатный пробный период настроен некорректно (0 дней) — обратись в поддержку")

    order_id = str(uuid.uuid4())
    base_key_email = f"{user['sub']}-{order_id[:8]}"

    result = await provisioning.provision_bundle(user["sub"], base_key_email, days)

    await shop_db.mark_trial_used(user["sub"])
    await shop_db.create_order_row(order_id, user["sub"], 0, "TRIAL", None, status="fulfilled")
    await shop_db.insert_transaction(user["sub"], f"trial:{order_id}", "succeeded", 0.0, "trial")
    return {"order_id": order_id, "status": "fulfilled", "payment_url": None, "provisioning": result}


@router.post("")
async def create_order(payload: CreateOrderIn, user: dict = Depends(get_current_user)):
    plan = await _get_plan(payload.plan_id)
    order_id = str(uuid.uuid4())

    await shop_db.create_order_row(order_id, user["sub"], plan["plan_id"], "BUNDLE", payload.payment_method)

    if payload.payment_method == "yookassa":
        pay = await payments.create_yookassa_payment(plan["price"], plan["plan_name"], order_id)
    elif payload.payment_method == "cryptobot":
        pay = await payments.create_cryptobot_invoice(plan["price"], plan["plan_name"], order_id)
    else:
        raise HTTPException(400, "Неизвестный способ оплаты")

    await shop_db.set_order_provider_payment_id(order_id, pay["payment_id"])
    return {"order_id": order_id, "status": "pending", "payment_url": pay["payment_url"]}


@router.get("/{order_id}")
async def get_order(order_id: str, user: dict = Depends(get_current_user)):
    order = await shop_db.get_order_row(order_id)
    if not order or order["identity"] != user["sub"]:
        raise HTTPException(404, "Заказ не найден")
    return {"order_id": order_id, "status": order["status"]}
