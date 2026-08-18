"""
Реферальная программа — v4.

v3 уже правильно читала telegram_id/referral_balance из реальной схемы
(без изобретённого referral_code). Что добавляет v4: реальные проценты
программы — ПОДТВЕРЖДЕНО по backup (`bot_settings`): referral_percentage=15,
referral_discount=10, referral_on_start_referrer_amount=20. Статический
текст на сайте ("10% лифтайм / 5% скидка другу") устарел относительно
реально настроенных в bot_settings значений (15%/10%) — значит их нельзя
хардкодить и в приложении, иначе рано или поздно они разойдутся ещё раз.
Теперь приложение показывает то же число, что реально начисляет бот.
"""
import os
from fastapi import APIRouter, Depends
from app.services import shop_db
from app.auth_deps import get_current_user

router = APIRouter()

BOT_USERNAME = os.getenv("REFERRAL_BOT_USERNAME", "VPNonLineRoBot")


@router.get("")
async def get_referral_info(user: dict = Depends(get_current_user)):
    info = await shop_db.get_referral_info(user["sub"])
    settings = await shop_db.get_public_settings()
    telegram_id = info["telegram_id"]
    return {
        "telegram_id": telegram_id,
        "referral_link": f"https://t.me/{BOT_USERNAME}?start=ref_{telegram_id}" if telegram_id else None,
        "invited_count": info["invited_count"],
        "referral_balance_rub": info["referral_balance_rub"],
        "referral_balance_all_rub": info["referral_balance_all_rub"],
        "referral_percentage": settings.get("referral_percentage", 0),
        "referral_discount_for_friend_percent": settings.get("referral_discount", 0),
        "referral_start_bonus_rub": settings.get("referral_on_start_referrer_amount", 0),
        "minimum_withdrawal_rub": settings.get("minimum_withdrawal", 0),
    }
