"""
Авторизация — v4, ПЕРЕДЕЛАНО под реальный механизм сайта.

КРИТИЧЕСКАЯ НАХОДКА v3->v4 (проверено напрямую на vpnonline.su, не
предположение): реальный сайт логинит по email+ПАРОЛЮ ("Email адрес" /
"Пароль" / "Войти в аккаунт"), а не по одноразовому коду на почту — код на
почту у сайта используется только в двух местах: подтверждение регистрации
("Подтверждение почты") и сброс пароля ("Сброс пароля" -> "Новый пароль").
Версия v3 этого файла реализовывала ВХОД по одноразовому коду — рабочий, но
несовместимый с реальным сайтом механизм: пользователь, зарегистрированный
на сайте (с паролем), не смог бы войти в приложение тем же способом, каким
входит на сайте. Теперь: email+пароль для входа (как на сайте), отдельная
регистрация с подтверждением по коду (как на сайте), отдельный сброс пароля
по коду (как на сайте).

Формат хэша пароля — bcrypt (подтверждено по реальному backup: хэши вида
"$2b$10$..."), поэтому здесь используется bcrypt, а не что-то придуманное.

БЕЗОПАСНОСТЬ:
1. Пароли никогда не сравниваются напрямую — только bcrypt.checkpw.
2. Коды подтверждения — secrets.randbelow (криптостойкий), не random.
3. Ограничение попыток ввода кода (5) и частоты запроса кода (60 сек),
   плюс лимит по IP на request-code (10 запросов / 10 минут).
4. [НОВОЕ] Лимит попыток входа по паролю — 10 неверных попыток на email
   за 15 минут блокируют дальнейшие попытки для этого email на 15 минут.
   Раньше (v3, только код) отдельного brute-force лимита на "неверный
   пароль" не было, потому что пароля не было вообще — теперь это новая
   поверхность атаки (перебор пароля), и её нужно закрывать отдельно.
5. Ответ на request-code для регистрации/сброса ВСЕГДА одинаковый (не
   раскрывает, существует ли email в базе) — иначе email-перечисление
   (enumeration): злоумышленник мог бы понять, какие email зарегистрированы,
   по разнице в ответе.
"""
import os
import re
import time
import secrets
from collections import defaultdict

import bcrypt
from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel, EmailStr, field_validator

from app.auth_deps import create_token
from app.services import shop_db, mailer

router = APIRouter()

CODE_TTL_SECONDS = 600  # 10 минут — как в реальных письмах сайта (см. присланные скриншоты)
RESEND_COOLDOWN_SECONDS = 60
MAX_CODE_ATTEMPTS = 5

LOGIN_MAX_ATTEMPTS = 10
LOGIN_LOCKOUT_SECONDS = 15 * 60

# In-memory — как и раньше, отмечено: в проде с несколькими инстансами
# бэкенда за балансировщиком это нужно вынести в Redis (общее состояние
# между процессами), иначе rate-limit считается только внутри одного
# процесса.
_reg_codes: dict[str, dict] = {}          # email -> {code, created_at, attempts, username, password_hash}
_reset_codes: dict[str, dict] = {}        # email -> {code, created_at, attempts}
_login_failures: dict[str, list[float]] = defaultdict(list)
_ip_requests: dict[str, list[float]] = defaultdict(list)
IP_WINDOW_SECONDS = 600
IP_MAX_REQUESTS = 10


def _check_ip_rate_limit(ip: str) -> None:
    now = time.time()
    bucket = _ip_requests[ip]
    bucket[:] = [t for t in bucket if now - t < IP_WINDOW_SECONDS]
    if len(bucket) >= IP_MAX_REQUESTS:
        raise HTTPException(429, "Слишком много запросов с этого адреса, попробуй позже")
    bucket.append(now)


def _check_login_lockout(email: str) -> None:
    now = time.time()
    bucket = _login_failures[email]
    bucket[:] = [t for t in bucket if now - t < LOGIN_LOCKOUT_SECONDS]
    if len(bucket) >= LOGIN_MAX_ATTEMPTS:
        raise HTTPException(429, "Слишком много неверных попыток входа, попробуй позже")


def _record_login_failure(email: str) -> None:
    _login_failures[email].append(time.time())


def _gen_code() -> str:
    return f"{secrets.randbelow(1_000_000):06d}"


def _hash_password(password: str) -> str:
    return bcrypt.hashpw(password.encode("utf-8"), bcrypt.gensalt()).decode("ascii")


def _check_password(password: str, password_hash: str | None) -> bool:
    if not password_hash:
        return False
    try:
        return bcrypt.checkpw(password.encode("utf-8"), password_hash.encode("utf-8"))
    except ValueError:
        # хэш повреждён/не bcrypt-формата — считаем неверным, не роняем запрос
        return False


class RegisterRequestIn(BaseModel):
    email: EmailStr
    username: str | None = None
    password: str

    @field_validator("password")
    @classmethod
    def _min_len(cls, v: str) -> str:
        if len(v) < 6:
            raise ValueError("Пароль должен быть не короче 6 символов")
        return v

    @field_validator("username")
    @classmethod
    def _clean_username(cls, v: str | None) -> str | None:
        if v is None or v.strip() == "":
            return None
        v = v.strip()
        if not re.fullmatch(r"[\w\- .]{1,32}", v, flags=re.UNICODE):
            raise ValueError("Имя пользователя: до 32 символов, без спецсимволов")
        return v


class RegisterConfirmIn(BaseModel):
    email: EmailStr
    code: str


class LoginIn(BaseModel):
    email: EmailStr
    password: str


class ResetRequestIn(BaseModel):
    email: EmailStr


class ResetConfirmIn(BaseModel):
    email: EmailStr
    code: str
    new_password: str

    @field_validator("new_password")
    @classmethod
    def _min_len(cls, v: str) -> str:
        if len(v) < 6:
            raise ValueError("Пароль должен быть не короче 6 символов")
        return v


@router.post("/register/request-code")
async def register_request_code(payload: RegisterRequestIn, request: Request):
    client_ip = request.client.host if request.client else "unknown"
    _check_ip_rate_limit(client_ip)

    existing_user = await shop_db.get_user_by_email(payload.email)
    now = time.time()
    pending = _reg_codes.get(payload.email)
    if pending and now - pending["created_at"] < RESEND_COOLDOWN_SECONDS:
        raise HTTPException(429, "Код уже отправлен, подожди немного перед повторной отправкой")

    if existing_user is None:
        code = _gen_code()
        _reg_codes[payload.email] = {
            "code": code,
            "created_at": now,
            "attempts": 0,
            "username": payload.username,
            "password_hash": _hash_password(payload.password),
        }
        # v4.1: реальная отправка письма вместо print (см. app/services/mailer.py)
        await mailer.send_registration_code(payload.email, code)
    # Ответ одинаковый независимо от того, существует ли email — защита от
    # email-перечисления (enumeration). Если email уже занят, письмо просто
    # не уходит, но клиент не может отличить это от "письмо отправлено".
    return {"sent": True}


@router.post("/register/confirm")
async def register_confirm(payload: RegisterConfirmIn):
    entry = _reg_codes.get(payload.email)
    if not entry:
        raise HTTPException(400, "Код не запрашивался или email уже зарегистрирован")
    if time.time() - entry["created_at"] > CODE_TTL_SECONDS:
        del _reg_codes[payload.email]
        raise HTTPException(400, "Код истёк, запроси новый")
    if entry["attempts"] >= MAX_CODE_ATTEMPTS:
        del _reg_codes[payload.email]
        raise HTTPException(429, "Слишком много попыток, запроси новый код")
    if not secrets.compare_digest(entry["code"], payload.code):
        entry["attempts"] += 1
        raise HTTPException(400, "Неверный код")

    del _reg_codes[payload.email]
    # [НОВОЕ] Повторная проверка прямо перед вставкой — email не UNIQUE на
    # уровне схемы БД бота, значит гонка "два одновременных подтверждения
    # одного и того же email" не будет остановлена самой БД. Между
    # request-code и confirm могло пройти до 10 минут — кто-то другой мог
    # успеть зарегистрировать этот же email через бота/сайт за это время.
    if await shop_db.get_user_by_email(payload.email) is not None:
        raise HTTPException(409, "Этот email уже зарегистрирован")
    telegram_id = await shop_db.create_web_user(payload.email, entry["username"], entry["password_hash"])
    token = create_token(subject=payload.email)
    return {"access_token": token, "token_type": "bearer", "telegram_id": telegram_id}


@router.post("/login")
async def login(payload: LoginIn, request: Request):
    client_ip = request.client.host if request.client else "unknown"
    _check_ip_rate_limit(client_ip)
    _check_login_lockout(payload.email)

    user = await shop_db.get_user_by_email(payload.email)
    # Намеренно НЕ различаем "email не найден" и "неверный пароль" в ответе —
    # иначе это тоже email-перечисление. checkpw против password_hash=None
    # безопасно возвращает False (см. _check_password).
    if not user or not _check_password(payload.password, user.get("password_hash")):
        _record_login_failure(payload.email)
        raise HTTPException(401, "Неверный email или пароль")

    if user.get("is_banned"):
        raise HTTPException(403, "Аккаунт заблокирован")

    token = create_token(subject=payload.email)
    return {"access_token": token, "token_type": "bearer"}


@router.post("/password-reset/request-code")
async def password_reset_request(payload: ResetRequestIn, request: Request):
    client_ip = request.client.host if request.client else "unknown"
    _check_ip_rate_limit(client_ip)

    user = await shop_db.get_user_by_email(payload.email)
    now = time.time()
    pending = _reset_codes.get(payload.email)
    if pending and now - pending["created_at"] < RESEND_COOLDOWN_SECONDS:
        raise HTTPException(429, "Код уже отправлен, подожди немного перед повторной отправкой")

    if user is not None:
        code = _gen_code()
        _reset_codes[payload.email] = {"code": code, "created_at": now, "attempts": 0}
        # v4.1: реальная отправка письма вместо print
        await mailer.send_password_reset_code(payload.email, code)
    # Тот же принцип: ответ не выдаёт, существует ли аккаунт.
    return {"sent": True}


@router.post("/password-reset/confirm")
async def password_reset_confirm(payload: ResetConfirmIn):
    entry = _reset_codes.get(payload.email)
    if not entry:
        raise HTTPException(400, "Код не запрашивался")
    if time.time() - entry["created_at"] > CODE_TTL_SECONDS:
        del _reset_codes[payload.email]
        raise HTTPException(400, "Код истёк, запроси новый")
    if entry["attempts"] >= MAX_CODE_ATTEMPTS:
        del _reset_codes[payload.email]
        raise HTTPException(429, "Слишком много попыток, запроси новый код")
    if not secrets.compare_digest(entry["code"], payload.code):
        entry["attempts"] += 1
        raise HTTPException(400, "Неверный код")

    del _reset_codes[payload.email]
    await shop_db.update_password_hash(payload.email, _hash_password(payload.new_password))
    return {"ok": True}
