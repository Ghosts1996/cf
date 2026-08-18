"""
Точка входа backend'а — v3, продакшн-настройки.

Добавлено относительно предыдущей версии:
1. Проверка обязательных .env переменных ПРИ СТАРТЕ, а не при первом
   запросе — если что-то не заполнено, процесс падает сразу с понятным
   сообщением, вместо того чтобы поднять сервер и ловить неясные 500-ки
   на первом реальном запросе пользователя.
2. CORS — без него Flutter Web / Telegram Mini App, обращающиеся с
   другого origin, получали бы заблокированные браузером запросы.
3. Единый обработчик необработанных исключений — вместо "голого" traceback
   наружу (утечка деталей инфраструктуры) отдаём JSON с order-friendly
   сообщением, а полный traceback пишем только в серверный лог.
4. Логирование — без секретов (токенов, паролей, JWT) в логах по умолчанию.
"""
import os
import logging
import sys

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.middleware.gzip import GZipMiddleware
from fastapi.responses import JSONResponse

from app.routes import auth, keys, plans, orders, webhooks, servers, balance, referral, settings as settings_route

logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    stream=sys.stdout,
)
logger = logging.getLogger("vpnonline")

REQUIRED_ENV = ["DATABASE_URL", "JWT_SECRET"]


def _validate_env() -> None:
    missing = [name for name in REQUIRED_ENV if not os.getenv(name)]
    if missing:
        raise RuntimeError(
            "Не заполнены обязательные переменные в .env: "
            + ", ".join(missing)
            + ". Скопируй backend/.env.example в backend/.env и заполни."
        )
    if os.getenv("JWT_SECRET") == "change-me":
        raise RuntimeError(
            "JWT_SECRET оставлен значением по умолчанию 'change-me' — "
            "сгенерируй случайную строку (`openssl rand -hex 32`) перед запуском в проде."
        )
    # v4.1: SMTP — не hard-fail (сервер всё же может быть полезен без почты,
    # например пока проверяешь остальное), но громкое предупреждение в
    # логах при каждом старте, чтобы это не потерялось: без SMTP реальная
    # регистрация новых пользователей и сброс пароля молча не работают.
    if not (os.getenv("SMTP_HOST") and os.getenv("SMTP_USER") and os.getenv("SMTP_PASSWORD")):
        logger.warning(
            "SMTP не настроен (SMTP_HOST/SMTP_USER/SMTP_PASSWORD пустые) — "
            "регистрация и сброс пароля НЕ будут отправлять письма реальным пользователям."
        )


_validate_env()

app = FastAPI(
    title="VPN onLine API bridge",
    description="Мост между приложением, Telegram-ботом, сайтом, 3x-ui и платёжными провайдерами.",
    version="0.4.0",
)

_allowed_origins = [o.strip() for o in os.getenv("CORS_ORIGINS", "https://vpnonline.su,https://vpnonline.shop").split(",") if o.strip()]

app.add_middleware(
    CORSMiddleware,
    allow_origins=_allowed_origins,
    allow_credentials=False,  # авторизация через Bearer-заголовок, не через cookie — credentials не нужны
    allow_methods=["GET", "POST"],
    allow_headers=["Authorization", "Content-Type", "Crypto-Pay-API-Signature"],
)
app.add_middleware(GZipMiddleware, minimum_size=512)

app.include_router(auth.router, prefix="/v1/auth", tags=["auth"])
app.include_router(keys.router, prefix="/v1/keys", tags=["keys"])
app.include_router(plans.router, prefix="/v1/plans", tags=["plans"])
app.include_router(orders.router, prefix="/v1/orders", tags=["orders"])
app.include_router(webhooks.router, prefix="/v1/webhooks", tags=["webhooks"])
app.include_router(servers.router, prefix="/v1/servers", tags=["servers"])
app.include_router(balance.router, prefix="/v1/balance", tags=["balance"])
app.include_router(referral.router, prefix="/v1/referral", tags=["referral"])
app.include_router(settings_route.router, prefix="/v1/settings", tags=["settings"])


@app.exception_handler(Exception)
async def unhandled_exception_handler(request: Request, exc: Exception):
    logger.exception("Необработанная ошибка на %s %s", request.method, request.url.path)
    return JSONResponse(status_code=500, content={"detail": "Внутренняя ошибка сервера"})


@app.get("/health")
def health():
    return {"status": "ok"}
