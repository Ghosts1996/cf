"""
Баланс пользователя — читается из ТОЙ ЖЕ БД, что использует бот. v3: теперь
возвращает и основной, и реферальный баланс (оба реально существуют в схеме
users), а не только один.
"""
from fastapi import APIRouter, Depends
from app.services import shop_db
from app.auth_deps import get_current_user

router = APIRouter()


@router.get("")
async def get_balance(user: dict = Depends(get_current_user)):
    return await shop_db.get_user_balance(user["sub"])
