"""
РЕАЛЬНАЯ проверка токена вместо прежней заглушки `dev-token-{email}`.

БАГ/УЯЗВИМОСТЬ, которая была раньше: токен вида "dev-token-bikoev1996@gmail.com"
мог подделать кто угодно, просто зная (или угадав) чужой email — сервер
никак не проверял подлинность. Это критическая уязвимость (полный обход
авторизации). Теперь токен — подписанный JWT (HMAC-SHA256, секрет из .env),
и подпись проверяется на каждый защищённый запрос.
"""
import os
import time
import jwt
from fastapi import Header, HTTPException

JWT_SECRET = os.getenv("JWT_SECRET", "")
JWT_ALG = "HS256"
JWT_TTL_SECONDS = 60 * 60 * 24 * 30  # 30 дней


def create_token(subject: str) -> str:
    if not JWT_SECRET or JWT_SECRET == "change-me":
        raise RuntimeError(
            "JWT_SECRET не задан или оставлен значением по умолчанию — "
            "сгенерируй случайную строку (например `openssl rand -hex 32`) "
            "и пропиши в .env перед запуском в проде."
        )
    now = int(time.time())
    payload = {"sub": subject, "iat": now, "exp": now + JWT_TTL_SECONDS}
    return jwt.encode(payload, JWT_SECRET, algorithm=JWT_ALG)


def _decode(token: str) -> dict:
    try:
        return jwt.decode(token, JWT_SECRET, algorithms=[JWT_ALG])
    except jwt.PyJWTError:
        raise HTTPException(401, "Невалидный или истёкший токен")


async def get_current_user(authorization: str = Header(default="")) -> dict:
    """FastAPI dependency — подставь Depends(get_current_user) в любой защищённый роут."""
    if not authorization.startswith("Bearer "):
        raise HTTPException(401, "Нужен заголовок Authorization: Bearer <token>")
    token = authorization.removeprefix("Bearer ").strip()
    return _decode(token)
