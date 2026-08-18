import os
import re
import json
import uuid as uuid_lib
import secrets
import random
import smtplib
import hashlib
import hmac
import urllib.request
import urllib.error
import logging
from datetime import datetime, timedelta
from functools import wraps
import bcrypt
from email.mime.text import MIMEText
from email.header import Header
from flask import Blueprint, request, jsonify, current_app
from itsdangerous import URLSafeTimedSerializer, SignatureExpired, BadSignature

from shop_bot.data_manager.database import (
    register_email_user, get_user_by_email, get_user, get_balance,
    get_user_keys, get_all_hosts, get_plans_for_host, get_setting,
    adjust_user_balance, add_new_key, get_plan_by_id, register_user_if_not_exists,
    set_trial_used, get_key_by_email, get_referral_count, get_referral_balance_all,
    update_user_password, get_key_by_id, upgrade_key_devices, update_key_info,
    deduct_from_balance, save_verification_code, get_verification_code,
    delete_verification_code, cleanup_expired_verification_codes,
    check_and_record_rate_limit
)
from shop_bot.modules import xui_api

logger = logging.getLogger(__name__)

api_bp = Blueprint('api_v1', __name__, url_prefix='/api/v1')

@api_bp.before_request
def handle_options():
    if request.method == 'OPTIONS':
        response = current_app.make_default_options_response()
        response.headers['Access-Control-Allow-Origin'] = '*'
        response.headers['Access-Control-Allow-Headers'] = 'Content-Type,Authorization,X-API-Key'
        response.headers['Access-Control-Allow-Methods'] = 'GET,POST,OPTIONS'
        return response

@api_bp.after_request
def add_cors_headers(response):
    response.headers['Access-Control-Allow-Origin'] = '*'
    response.headers['Access-Control-Allow-Headers'] = 'Content-Type,Authorization,X-API-Key'
    response.headers['Access-Control-Allow-Methods'] = 'GET,POST,OPTIONS'
    return response

# API Key for securing communications between website and bot server
def require_api_key(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        # БАГ/УЯЗВИМОСТЬ, которая была: если SHOPBOT_API_KEY не задан в .env,
        # ключом становилась строка 'default_secure_shopbot_api_key' — она
        # видна в открытом форке на GitHub, значит "секрет" был публичным.
        # Теперь при отсутствии переменной окружения сервер отвечает 500,
        # а не тихо принимает всем известный ключ.
        # ВАЖНО (архитектурная особенность, не баг, который можно "починить"
        # кодом): этот ключ всё равно будет виден любому, кто декомпилирует
        # Android/iOS-приложение — так работает любой статический секрет,
        # встроенный в клиент. Он защищает не от целенаправленной атаки, а
        # от случайных ботов/сканеров, которые не читали код приложения.
        # Настоящая защита конкретного пользователя — это require_user_auth
        # (токен сессии), который просто знанием API-ключа не подделать.
        expected_key = os.getenv('SHOPBOT_API_KEY')
        if not expected_key:
            logger.error("SHOPBOT_API_KEY не задан в .env — API отключён из соображений безопасности")
            return jsonify({"ok": False, "error": "Server misconfigured"}), 500
        provided_key = request.headers.get('X-API-Key')
        if not provided_key or not hmac.compare_digest(provided_key, expected_key):
            return jsonify({"ok": False, "error": "Unauthorized: Invalid or missing API key"}), 401
        return f(*args, **kwargs)
    return decorated

# User session serializer using Flask SECRET_KEY
def get_serializer():
    return URLSafeTimedSerializer(current_app.config['SECRET_KEY'])

# User token verification decorator
def require_user_auth(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        auth_header = request.headers.get('Authorization')
        if not auth_header or not auth_header.startswith('Bearer '):
            return jsonify({"ok": False, "error": "Unauthorized: Missing user token"}), 401
        
        token = auth_header.split(" ")[1]
        serializer = get_serializer()
        try:
            # Token valid for 30 days
            data = serializer.loads(token, max_age=86400 * 30)
            user_id = data.get("user_id")
            if not user_id:
                return jsonify({"ok": False, "error": "Unauthorized: Invalid token payload"}), 401
            
            user = get_user(user_id)
            if not user:
                return jsonify({"ok": False, "error": "Unauthorized: User not found"}), 401
            
            request.user_id = user_id
            request.user = user
        except SignatureExpired:
            return jsonify({"ok": False, "error": "Unauthorized: Token expired"}), 401
        except BadSignature:
            return jsonify({"ok": False, "error": "Unauthorized: Invalid token signature"}), 401
        
        return f(*args, **kwargs)
    return decorated


# ==========================================
# 📧 EMAIL VERIFICATION & PASSWORD RESET SYSTEM
# ==========================================

# [УБРАНО] verification_codes и _email_send_log больше не хранятся в
# памяти процесса (см. save_verification_code/get_verification_code/
# check_and_record_rate_limit в database.py) — это было небезопасно при
# нескольких воркерах Flask, см. REPORT.md.
_RATE_LIMIT_MAX = 3      # max attempts
_RATE_LIMIT_WINDOW = 600  # seconds (10 min)

def _check_rate_limit(email: str) -> bool:
    """Returns True if sending is allowed, False if rate limit exceeded.
    Теперь считает через БД (email_send_log), а не словарь в памяти —
    корректно работает независимо от числа воркеров Flask."""
    return check_and_record_rate_limit(email, _RATE_LIMIT_MAX, _RATE_LIMIT_WINDOW)

def _cleanup_verification_codes():
    """Remove expired verification codes to prevent memory growth."""
    cleanup_expired_verification_codes()

def send_email(to_email, subject, body):
    gmail_user = os.getenv('GMAIL_USER', 'VPNonLineRoBot@gmail.com')
    gmail_password = os.getenv('GMAIL_APP_PASSWORD')
    if not gmail_password:
        # БАГ/УЯЗВИМОСТЬ, которая была: здесь был реальный Gmail App Password
        # прямо в исходном коде как fallback-значение по умолчанию (виден в
        # git-истории репозитория). Любой, у кого была эта копия кода/бэкапа,
        # имел рабочий пароль от твоей почты рассылки. ОБЯЗАТЕЛЬНО отзови
        # тот App Password в аккаунте Google прямо сейчас (Google Account ->
        # Security -> App Passwords -> Revoke) и сгенерируй новый — этот
        # больше не должен использоваться, он был скомпрометирован самим
        # фактом нахождения в коде/бэкапе.
        logger.error("GMAIL_APP_PASSWORD не задан в .env — письмо не отправлено")
        return False
    
    msg = MIMEText(body, 'html', 'utf-8')
    msg['Subject'] = Header(subject, 'utf-8')
    msg['From'] = gmail_user
    msg['To'] = to_email
    
    try:
        # Try SSL port 465
        server = smtplib.SMTP_SSL('smtp.gmail.com', 465, timeout=10)
        server.login(gmail_user, gmail_password)
        server.sendmail(gmail_user, [to_email], msg.as_string())
        server.close()
        return True
    except Exception as e:
        logger.error(f"Failed to send email via SSL: {e}")
        # Fallback to port 587 with STARTTLS
        try:
            server = smtplib.SMTP('smtp.gmail.com', 587, timeout=10)
            server.ehlo()
            server.starttls()
            server.login(gmail_user, gmail_password)
            server.sendmail(gmail_user, [to_email], msg.as_string())
            server.close()
            return True
        except Exception as e_tls:
            logger.error(f"Failed to send email via STARTTLS: {e_tls}")
            return False

def generate_verification_code():
    return "".join(random.choices("0123456789", k=6))


def _mask_email(email: str) -> str:
    """Маскирует email для логов: ab***@example.com вместо полного адреса.
    Требование "логи не должны хранить персональные данные" — раньше сюда
    писался email целиком открытым текстом."""
    try:
        local, domain = email.split("@", 1)
        visible = local[:2]
        return f"{visible}***@{domain}"
    except Exception:
        return "***"


# ==========================================
# 🔐 AUTHENTICATION ENDPOINTS
# ==========================================

@api_bp.route('/auth/register/send-code', methods=['POST'])
@require_api_key
def api_register_send_code():
    data = request.get_json() or {}
    email = (data.get('email') or '').strip().lower()
    
    if not email or '@' not in email or '.' not in email:
        return jsonify({"ok": False, "error": "Неверный формат email адреса"}), 400

    # Rate limit check
    if not _check_rate_limit(f"register:{email}"):
        return jsonify({"ok": False, "error": "Слишком много попыток. Подождите 10 минут."}), 429

    # Check if user already exists
    existing = get_user_by_email(email)
    if existing:
        return jsonify({"ok": False, "error": "Пользователь с такой почтой уже зарегистрирован"}), 409

    # Cleanup stale codes
    _cleanup_verification_codes()

    # Generate and save code
    code = generate_verification_code()
    expiry = datetime.now() + timedelta(minutes=10)
    save_verification_code(email, 'register', code, expiry)
    
    # Send email
    subject = "Код подтверждения регистрации — VPN Online Shop"
    body = f"""
    <div style="background-color: #0b0c16; color: #ffffff; padding: 30px; font-family: 'Inter', Arial, sans-serif; border-radius: 12px; max-width: 500px; margin: 0 auto; border: 1px solid rgba(168, 85, 247, 0.2);">
        <h2 style="color: #c084fc; text-align: center; margin-top: 0;">VPN Online Shop</h2>
        <p style="font-size: 1rem; line-height: 1.5; color: #e2e8f0; text-align: center;">Здравствуйте!</p>
        <p style="font-size: 1rem; line-height: 1.5; color: #e2e8f0; text-align: center;">Вы регистрируетесь в личном кабинете VPN Online Shop. Пожалуйста, используйте следующий код подтверждения:</p>
        <div style="text-align: center; margin: 24px 0;">
            <span style="font-size: 2rem; font-weight: 800; letter-spacing: 4px; color: #c084fc; background: rgba(168, 85, 247, 0.1); padding: 12px 24px; border-radius: 8px; border: 1px solid rgba(168, 85, 247, 0.3); display: inline-block;">{code}</span>
        </div>
        <p style="font-size: 0.85rem; color: #94a3b8; line-height: 1.5; text-align: center;">Код действителен в течение 10 минут. Если вы не запрашивали этот код, просто проигнорируйте это письмо.</p>
    </div>
    """
    
    if send_email(email, subject, body):
        logger.info(f"Sent registration verification code to {_mask_email(email)}")
        return jsonify({"ok": True}), 200
    else:
        return jsonify({"ok": False, "error": "Не удалось отправить письмо с кодом. Попробуйте позже."}), 500


@api_bp.route('/auth/register', methods=['POST'])
@require_api_key
def api_register():
    data = request.get_json() or {}
    email = (data.get('email') or '').strip().lower()
    password = data.get('password')
    username = (data.get('username') or '').strip()
    code = (data.get('code') or '').strip()

    if not email or not password or not code:
        return jsonify({"ok": False, "error": "Заполните все обязательные поля"}), 400

    # Basic email format check
    if '@' not in email or '.' not in email:
        return jsonify({"ok": False, "error": "Неверный формат email адреса"}), 400

    # Check code
    record = get_verification_code(email, 'register')
    if not record or record['code'] != code or datetime.now() > record['expires_at']:
        return jsonify({"ok": False, "error": "Неверный или устаревший код подтверждения"}), 400

    # Check if user already exists
    existing = get_user_by_email(email)
    if existing:
        return jsonify({"ok": False, "error": "Пользователь с такой почтой уже зарегистрирован"}), 409

    # Remove verification code once verified
    delete_verification_code(email, 'register')

    # Hash the password securely using bcrypt
    salt = bcrypt.gensalt(10)
    password_hash = bcrypt.hashpw(password.encode('utf-8'), salt).decode('utf-8')

    # Register in DB
    new_user_id = register_email_user(email, password_hash, username or None)
    if not new_user_id:
        return jsonify({"ok": False, "error": "Ошибка при регистрации"}), 500

    logger.info(f"Registered new verified email user: {_mask_email(email)} (ID: {new_user_id})")

    # Generate session token
    serializer = get_serializer()
    token = serializer.dumps({"user_id": new_user_id})

    return jsonify({
        "ok": True,
        "token": token,
        "user": {
            "id": new_user_id,
            "email": email,
            "username": username or None,
            "balance": 0.0
        }
    }), 201


@api_bp.route('/auth/reset-password/send-code', methods=['POST'])
@require_api_key
def api_reset_password_send_code():
    data = request.get_json() or {}
    email = (data.get('email') or '').strip().lower()

    if not email:
        return jsonify({"ok": False, "error": "Укажите ваш email"}), 400

    # Rate limit check
    if not _check_rate_limit(f"reset:{email}"):
        return jsonify({"ok": False, "error": "Слишком много попыток. Подождите 10 минут."}), 429

    user = get_user_by_email(email)
    # БАГ/УЯЗВИМОСТЬ, которая была: если пользователя с таким email нет,
    # эндпоинт отвечал 404 "не найден" — по этому ответу кто угодно мог
    # перебором узнать, какие email зарегистрированы в сервисе (email
    # enumeration, классический OWASP-пункт). Теперь ответ ОДИНАКОВЫЙ и
    # для существующего, и для несуществующего email — письмо реально
    # уходит только если пользователь есть, но ответ этого не выдаёт.
    if not user:
        return jsonify({"ok": True}), 200

    # Cleanup stale codes
    _cleanup_verification_codes()

    # Generate and save code
    code = generate_verification_code()
    expiry = datetime.now() + timedelta(minutes=10)
    save_verification_code(email, 'reset', code, expiry)
    
    # Send email
    subject = "Восстановление пароля — VPN Online Shop"
    body = f"""
    <div style="background-color: #0b0c16; color: #ffffff; padding: 30px; font-family: 'Inter', Arial, sans-serif; border-radius: 12px; max-width: 500px; margin: 0 auto; border: 1px solid rgba(168, 85, 247, 0.2);">
        <h2 style="color: #c084fc; text-align: center; margin-top: 0;">VPN Online Shop</h2>
        <p style="font-size: 1rem; line-height: 1.5; color: #e2e8f0; text-align: center;">Здравствуйте!</p>
        <p style="font-size: 1rem; line-height: 1.5; color: #e2e8f0; text-align: center;">Вы запросили сброс пароля от личного кабинета VPN Online Shop. Пожалуйста, используйте следующий код для подтверждения:</p>
        <div style="text-align: center; margin: 24px 0;">
            <span style="font-size: 2rem; font-weight: 800; letter-spacing: 4px; color: #c084fc; background: rgba(168, 85, 247, 0.1); padding: 12px 24px; border-radius: 8px; border: 1px solid rgba(168, 85, 247, 0.3); display: inline-block;">{code}</span>
        </div>
        <p style="font-size: 0.85rem; color: #94a3b8; line-height: 1.5; text-align: center;">Код действителен в течение 10 минут. Если вы не запрашивали сброс пароля, просто проигнорируйте это письмо.</p>
    </div>
    """
    
    if send_email(email, subject, body):
        logger.info(f"Sent password reset code to {_mask_email(email)}")
        return jsonify({"ok": True}), 200
    else:
        return jsonify({"ok": False, "error": "Не удалось отправить письмо с кодом. Попробуйте позже."}), 500


@api_bp.route('/auth/reset-password/confirm', methods=['POST'])
@require_api_key
def api_reset_password_confirm():
    data = request.get_json() or {}
    email = (data.get('email') or '').strip().lower()
    code = (data.get('code') or '').strip()
    new_password = data.get('new_password')
    
    if not email or not code or not new_password:
        return jsonify({"ok": False, "error": "Заполните все обязательные поля"}), 400
        
    if len(new_password) < 6:
        return jsonify({"ok": False, "error": "Пароль должен быть не менее 6 символов"}), 400

    # Проверяем код ПЕРЕД поиском пользователя: если email не существовал,
    # для него в принципе не мог быть сгенерирован код на предыдущем шаге —
    # запись просто не найдётся, и ответ будет тем же "неверный код", что и
    # для настоящего email с неправильным кодом. Так ответ не выдаёт, был
    # ли email вообще зарегистрирован (см. фикс enumeration выше по файлу).
    record = get_verification_code(email, 'reset')
    if not record or record['code'] != code or datetime.now() > record['expires_at']:
        return jsonify({"ok": False, "error": "Неверный или устаревший код подтверждения"}), 400

    user = get_user_by_email(email)
    if not user:
        return jsonify({"ok": False, "error": "Неверный или устаревший код подтверждения"}), 400

    # Remove verification code once verified
    delete_verification_code(email, 'reset')
    
    # Hash password
    salt = bcrypt.gensalt(10)
    password_hash = bcrypt.hashpw(new_password.encode('utf-8'), salt).decode('utf-8')
    
    # Update password in DB
    success = update_user_password(user['telegram_id'], password_hash)
    if success:
        logger.info(f"Successfully updated password for user_id {user['telegram_id']}")
        return jsonify({"ok": True}), 200
    else:
        return jsonify({"ok": False, "error": "Не удалось обновить пароль. Попробуйте позже."}), 500



@api_bp.route('/auth/login', methods=['POST'])
@require_api_key
def api_login():
    data = request.get_json() or {}
    email = (data.get('email') or '').strip().lower()
    password = data.get('password')

    if not email or not password:
        return jsonify({"ok": False, "error": "Missing email or password"}), 400

    user = get_user_by_email(email)
    if not user or not user.get('password_hash'):
        return jsonify({"ok": False, "error": "Invalid email or password"}), 401

    # Verify password hash
    pw_matches = bcrypt.checkpw(password.encode('utf-8'), user['password_hash'].encode('utf-8'))
    if not pw_matches:
        return jsonify({"ok": False, "error": "Invalid email or password"}), 401

    # Generate session token
    serializer = get_serializer()
    token = serializer.dumps({"user_id": user['telegram_id']})

    return jsonify({
        "ok": True,
        "token": token,
        "user": {
            "id": user['telegram_id'],
            "email": user['email'],
            "username": user['username'],
            "balance": user.get('balance') or 0.0
        }
    })


@api_bp.route('/auth/telegram', methods=['POST'])
@require_api_key
def api_telegram_auth():
    data = request.get_json() or {}
    
    # Check required fields
    telegram_id_val = data.get('id')
    received_hash = data.get('hash')
    
    if not telegram_id_val or not received_hash:
        return jsonify({"ok": False, "error": "Missing Telegram auth details"}), 400
        
    try:
        telegram_id = int(telegram_id_val)
    except ValueError:
        return jsonify({"ok": False, "error": "Invalid Telegram ID"}), 400
        
    # Get Bot Token from DB settings to verify hash
    bot_token = get_setting("telegram_bot_token")
    if not bot_token:
        # Development/Fallback bypass if bot token is not configured on the server yet
        logger.warning("telegram_bot_token is not configured, skipping widget hash validation for safety")
    else:
        bot_token = bot_token.strip()
        # Build check string - only include official Telegram auth fields
        allowed_keys = {'id', 'first_name', 'last_name', 'username', 'photo_url', 'auth_date'}
        sorted_keys = sorted([k for k in data.keys() if k in allowed_keys])
        data_check_list = [f"{k}={data[k]}" for k in sorted_keys]
        data_check_string = "\n".join(data_check_list)
        
        # Calculate SHA256 of bot token
        secret_key = hashlib.sha256(bot_token.encode('utf-8')).digest()
        calculated_hash = hmac.new(secret_key, data_check_string.encode('utf-8'), hashlib.sha256).hexdigest()
        
        if not hmac.compare_digest(calculated_hash, received_hash):
            return jsonify({"ok": False, "error": "Signature verification failed"}), 400

    # User exists or auto-register them
    username = data.get('username') or f"user_{telegram_id}"
    register_user_if_not_exists(telegram_id, username, None)
    
    # Load updated user data
    user = get_user(telegram_id)
    balance = get_balance(telegram_id)
    
    # Generate session token
    serializer = get_serializer()
    token = serializer.dumps({"user_id": telegram_id})
    
    return jsonify({
        "ok": True,
        "token": token,
        "user": {
            "id": telegram_id,
            "email": user.get('email') if user else None,
            "username": user.get('username') if user else username,
            "balance": balance or 0.0
        }
    })


@api_bp.route('/auth/telegram-webapp', methods=['POST'])
@require_api_key
def api_telegram_webapp_auth():
    """Authenticates user via Telegram WebApp initData string."""
    data = request.get_json() or {}
    init_data_raw = data.get('initData') or data.get('init_data')
    
    if not init_data_raw:
        return jsonify({"ok": False, "error": "Missing Telegram WebApp initData"}), 400

    bot_token = get_setting("telegram_bot_token")
    parsed_data = {}
    
    try:
        from urllib.parse import parse_qs
        parsed = parse_qs(init_data_raw, keep_blank_values=True)
        # Flatten query dict values
        parsed_data = {k: v[0] for k, v in parsed.items()}
    except Exception as e:
        logger.error(f"Error parsing initData: {e}")
        return jsonify({"ok": False, "error": "Invalid initData format"}), 400

    received_hash = parsed_data.get('hash')
    user_json = parsed_data.get('user')

    if not received_hash or not user_json:
        return jsonify({"ok": False, "error": "Invalid initData payload"}), 400

    try:
        tg_user = json.loads(user_json)
        telegram_id = int(tg_user.get('id'))
    except Exception as e:
        logger.error(f"Error reading user from initData: {e}")
        return jsonify({"ok": False, "error": "Invalid Telegram user data"}), 400

    # Validate HMAC signature using bot token if configured
    if bot_token:
        bot_token = bot_token.strip()
        # Build check_string: all keys except 'hash', sorted alphabetically, key=value joined by \n
        data_check_list = [f"{k}={parsed_data[k]}" for k in sorted(parsed_data.keys()) if k != 'hash']
        data_check_string = "\n".join(data_check_list)

        # Telegram WebApp secret key derivation: HMAC-SHA256("WebAppData", bot_token)
        secret_key = hmac.new(b"WebAppData", bot_token.encode('utf-8'), hashlib.sha256).digest()
        calculated_hash = hmac.new(secret_key, data_check_string.encode('utf-8'), hashlib.sha256).hexdigest()

        if not hmac.compare_digest(calculated_hash, received_hash):
            logger.warning(f"WebApp auth hash mismatch for user {telegram_id}")
            return jsonify({"ok": False, "error": "Signature verification failed"}), 400
    else:
        logger.warning("telegram_bot_token is not configured, skipping WebApp initData hash validation")

    # Auto register/update user in database
    username = tg_user.get('username') or f"user_{telegram_id}"
    register_user_if_not_exists(telegram_id, username, None)

    user = get_user(telegram_id)
    balance = get_balance(telegram_id)

    # Issue session token
    serializer = get_serializer()
    token = serializer.dumps({"user_id": telegram_id})

    return jsonify({
        "ok": True,
        "token": token,
        "user": {
            "id": telegram_id,
            "email": user.get('email') if user else None,
            "username": user.get('username') if user else username,
            "balance": balance or 0.0
        }
    })



# ==========================================
# 👤 USER PROFILE & KEYS ENDPOINTS
# ==========================================

@api_bp.route('/user/profile', methods=['GET'])
@require_api_key
@require_user_auth
def api_profile():
    user = request.user
    balance = get_balance(request.user_id)
    trial_available = get_setting("trial_enabled") == "true" and not user.get("trial_used")
    bot_username = get_setting("telegram_bot_username") or "bot"
    return jsonify({
        "ok": True,
        "user": {
            "id": user['telegram_id'],
            "email": user['email'],
            "username": user['username'],
            "balance": balance,
            "registration_date": user.get('registration_date'),
            "trial_available": bool(trial_available),
            "referral_count": get_referral_count(user['telegram_id']),
            "referral_balance_all": float(get_referral_balance_all(user['telegram_id']) or 0.0),
            "referral_link": f"https://t.me/{bot_username}?start={user['telegram_id']}"
        }
    })


@api_bp.route('/user/trial', methods=['POST'])
@require_api_key
@require_user_auth
def api_claim_trial():
    user = request.user
    user_id = request.user_id
    
    if get_setting("trial_enabled") != "true":
        return jsonify({"ok": False, "error": "Тестовый период отключен"}), 400
        
    if user.get('trial_used'):
        return jsonify({"ok": False, "error": "Тестовый период уже был использован"}), 400
        
    # Check hosts
    hosts = get_all_hosts()
    if not hosts:
        return jsonify({"ok": False, "error": "Нет доступных серверов"}), 500
        
    try:
        # Generate candidate email
        raw_username = (user.get('username') or f'user{user_id}').lower()
        username_slug = re.sub(r"[^a-z0-9._-]", "_", raw_username).strip("_")[:16] or f"user{user_id}"
        base_local = f"trial_{username_slug}"
        candidate_local = base_local
        attempt = 1
        while True:
            candidate_email = f"{candidate_local}@bot.local"
            if not get_key_by_email(candidate_email):
                break
            attempt += 1
            candidate_local = f"{base_local}-{attempt}"
            if attempt > 100:
                import time as time_lib
                candidate_local = f"{base_local}-{int(time_lib.time())}"
                candidate_email = f"{candidate_local}@bot.local"
                break
                
        # Provision key on all hosts (sync)
        trial_days = int(get_setting("trial_duration_days") or "3")
        expiry_ms = int((datetime.now().timestamp() + (trial_days * 86400)) * 1000)
        
        result = xui_api.create_or_update_key_on_all_hosts_sync(
            email=candidate_email,
            days_to_add=None,
            expiry_timestamp_ms=expiry_ms
        )
        
        if not result:
            return jsonify({"ok": False, "error": "Не удалось создать ключ на серверах"}), 500
            
        set_trial_used(user_id)
        
        new_key_id = add_new_key(
            user_id=user_id,
            host_name="GLOBAL",
            xui_client_uuid=result['client_uuid'],
            key_email=result['email'],
            expiry_timestamp_ms=result['expiry_timestamp_ms']
        )
        
        return jsonify({
            "ok": True,
            "key": {
                "key_id": new_key_id,
                "host_name": "GLOBAL",
                "key_email": result['email'],
                "connection_string": result.get('connection_string') or '',
                "expiry_date": datetime.fromtimestamp(result['expiry_timestamp_ms'] / 1000).isoformat()
            }
        })
    except Exception as e:
        logger.error(f"Error creating trial via API: {e}", exc_info=True)
        return jsonify({"ok": False, "error": str(e)}), 500


@api_bp.route('/user/keys', methods=['GET'])
@require_api_key
@require_user_auth
def api_user_keys():
    keys = get_user_keys(request.user_id)
    for k in keys:
        try:
            details = xui_api.get_key_details_from_host_sync(k)
            if details:
                k['connection_string'] = details.get('connection_string') or ''
            else:
                k['connection_string'] = ''
        except Exception:
            k['connection_string'] = ''
    return jsonify({
        "ok": True,
        "keys": keys
    })


@api_bp.route('/key/upgrade-devices', methods=['POST'])
@require_api_key
@require_user_auth
def api_upgrade_key_devices():
    data = request.get_json() or {}
    key_id = data.get('key_id')
    
    if not key_id:
        return jsonify({"ok": False, "error": "Missing key_id"}), 400
        
    try:
        key_id = int(key_id)
    except (ValueError, TypeError):
        return jsonify({"ok": False, "error": "Invalid key_id"}), 400

    # Check if key exists and belongs to the user
    key = get_key_by_id(key_id)
    if not key or key['user_id'] != request.user_id:
        return jsonify({"ok": False, "error": "Key not found or access denied"}), 404
        
    current_limit = key.get('devices_limit') or 3
    if current_limit >= 4:
        return jsonify({"ok": False, "error": "Достигнут максимальный лимит устройств (максимум 4)"}), 400
        
    success, reason = upgrade_key_devices(key_id, 1)
    if not success:
        if reason == "insufficient_balance":
            return jsonify({"ok": False, "error": "Недостаточно средств на балансе. Требуется 50 RUB."}), 400
        elif reason == "limit_exceeded":
            return jsonify({"ok": False, "error": "Превышен максимальный лимит (максимум 4 устройства)"}), 400
        else:
            return jsonify({"ok": False, "error": f"Ошибка: {reason}"}), 500
            
    # Apply changes on XUI server immediately
    try:
        xui_api.create_or_update_key_on_all_hosts_sync(
            email=key['key_email'],
            devices_limit=current_limit + 1
        )
    except Exception as e:
        logger.error(f"Failed to sync upgraded devices limit to XUI for {key['key_email']}: {e}")
        
    return jsonify({
        "ok": True,
        "new_limit": current_limit + 1
    })


# ==========================================
# 📡 HOSTS & PLANS ENDPOINTS
# ==========================================

@api_bp.route('/hosts', methods=['GET'])
@require_api_key
def api_hosts():
    hosts = get_all_hosts()
    # [ИСПРАВЛЕНО — повторно, эта же уязвимость уже чинилась в другой
    # ветке этого проекта] host_url — приватный адрес админ-панели 3x-ui —
    # НЕ должен уходить клиенту. Эндпоинт защищён только статическим
    # @require_api_key (без @require_user_auth), а сам API-ключ достаётся
    # из любого собранного APK реверс-инжинирингом — то есть раньше адрес
    # каждой панели 3x-ui мог получить кто угодно, у кого есть сам APK.
    cleaned_hosts = []
    for h in hosts:
        # [НОВОЕ] connect_host/connect_port — публичный домен из
        # subscription_url (тот же самый, что и так уходит пользователю в
        # его VLESS-подписке — не секрет), нужен только для того, чтобы
        # приложение могло само измерить живой пинг с телефона до сервера
        # (см. app/lib/screens/servers_screen.dart). НЕ путать с host_url.
        connect_host = None
        connect_port = 443
        sub = h.get("subscription_url")
        if sub:
            try:
                from urllib.parse import urlparse
                parsed = urlparse(sub)
                connect_host = parsed.hostname
                connect_port = parsed.port or 443
            except Exception:
                connect_host = None
        cleaned_hosts.append({
            "host_name": h["host_name"],
            "subscription_url": h.get("subscription_url"),
            "connect_host": connect_host,
            "connect_port": connect_port,
        })
    return jsonify({
        "ok": True,
        "hosts": cleaned_hosts
    })


@api_bp.route('/plans', methods=['GET'])
@require_api_key
def api_plans():
    hosts = get_all_hosts()
    plans_by_host = {}
    
    # Load GLOBAL plans (used by the bot for unified global sub)
    global_plans = get_plans_for_host('GLOBAL')
    if global_plans:
        plans_by_host['GLOBAL'] = [
            {
                "plan_id": p["plan_id"],
                "plan_name": p["plan_name"],
                "months": p["months"],
                "price": p["price"]
            } for p in global_plans
        ]
        
    for h in hosts:
        host_name = h["host_name"]
        plans = get_plans_for_host(host_name)
        plans_by_host[host_name] = [
            {
                "plan_id": p["plan_id"],
                "plan_name": p["plan_name"],
                "months": p["months"],
                "price": p["price"]
            } for p in plans
        ]
    return jsonify({
        "ok": True,
        "plans": plans_by_host
    })


# ==========================================
# 🔑 KEY PROVISIONING & EXTENDING
# ==========================================

@api_bp.route('/key/create', methods=['POST'])
@require_api_key
@require_user_auth
def api_create_key():
    data = request.get_json() or {}
    plan_id = data.get('plan_id')
    
    if not plan_id:
        return jsonify({"ok": False, "error": "Missing plan_id"}), 400

    try:
        plan_id = int(plan_id)
    except (ValueError, TypeError):
        return jsonify({"ok": False, "error": "Invalid plan_id"}), 400

    # Fetch plan by ID
    selected_plan = get_plan_by_id(plan_id)

    if not selected_plan:
        return jsonify({"ok": False, "error": "Plan not found"}), 404

    price = selected_plan["price"]
    months = selected_plan["months"]

    # БАГ/УЯЗВИМОСТЬ, которая была: баланс проверялся отдельным вызовом
    # get_balance(), а списывался позже отдельным adjust_user_balance() —
    # между этими двумя действиями есть окно, в которое два параллельных
    # запроса (двойной тап по кнопке "купить", два устройства одного
    # аккаунта) могли ОБА пройти проверку баланса по одному и тому же
    # значению и оба списать деньги — баланс мог уйти в минус, а клиент
    # получить ключ фактически бесплатно. В самой БД уже есть готовая
    # атомарная функция deduct_from_balance() (BEGIN IMMEDIATE + проверка
    # внутри одной транзакции), она просто не была здесь подключена.
    # Списываем деньги ДО провижининга — деньги придётся вернуть, если
    # провижининг не удастся (см. ниже), это дешевле, чем допустить
    # повторное бесплатное получение ключа.
    if not deduct_from_balance(request.user_id, price):
        return jsonify({"ok": False, "error": "Недостаточный баланс"}), 400

    # Generate key details
    client_uuid = str(uuid_lib.uuid4())
    # Generate unique email for client
    user_email = request.user.get('email')
    if user_email and '@' in user_email:
        user_email_prefix = user_email.split('@')[0]
    else:
        user_email_prefix = request.user.get('username') or f"user_{request.user_id}"
    username_slug = re.sub(r"[^a-z0-9._-]", "_", user_email_prefix.lower()).strip("_")[:16] or f"user{request.user_id}"

    # Ensure unique email on XUI panel
    email_unique = f"{username_slug}-{secrets.token_hex(4)}@site.local"
    
    expiry_ms = int((datetime.now().timestamp() + (months * 86400)) * 1000)

    # 1) Provision the client on XUI panels
    # For unified Multi-Host Subscription, we provision on ALL hosts
    result = None
    try:
        result = xui_api.create_or_update_key_on_all_hosts_sync(
            email=email_unique,
            days_to_add=None,
            expiry_timestamp_ms=expiry_ms
        )
    except Exception as e:
        logger.error(f"Error provisioning key on XUI: {e}", exc_info=True)
        result = None

    if not result:
        # Деньги уже списаны атомарно выше — провижининг не удался, вернуть.
        adjust_user_balance(request.user_id, price)
        return jsonify({"ok": False, "error": "Provisioning failed on VPN panels."}), 500

    # 2) Save in database
    # For Multi-Host Subscription, we set host_name to 'GLOBAL'
    new_key_id = add_new_key(
        user_id=request.user_id,
        host_name="GLOBAL",
        xui_client_uuid=result.get("client_uuid") or client_uuid,
        key_email=email_unique,
        expiry_timestamp_ms=result.get("expiry_timestamp_ms") or expiry_ms
    )

    if not new_key_id:
        # Revert/delete client from panels if database save fails to prevent orphan clients
        try:
            for host in get_all_hosts():
                xui_api.delete_client_on_host_sync(host["host_name"], email_unique)
        except Exception as err:
            logger.error(f"Failed to cleanup client '{email_unique}' from panels: {err}")
        # Деньги уже списаны атомарно выше — сохранение в БД не удалось, вернуть.
        adjust_user_balance(request.user_id, price)
        return jsonify({"ok": False, "error": "Failed to save key in bot database"}), 500

    return jsonify({
        "ok": True,
        "key": {
            "key_id": new_key_id,
            "host_name": "GLOBAL",
            "key_email": email_unique,
            "xui_client_uuid": result.get("client_uuid"),
            "connection_string": result.get("connection_string"),
            "expiry_date": datetime.fromtimestamp((result.get("expiry_timestamp_ms") or expiry_ms) / 1000).isoformat()
        }
    }), 201


@api_bp.route('/key/extend', methods=['POST'])
@require_api_key
@require_user_auth
def api_extend_key():
    data = request.get_json() or {}
    key_id = data.get('key_id')
    plan_id = data.get('plan_id')

    if not key_id or not plan_id:
        return jsonify({"ok": False, "error": "Missing key_id or plan_id"}), 400

    try:
        key_id = int(key_id)
        plan_id = int(plan_id)
    except (ValueError, TypeError):
        return jsonify({"ok": False, "error": "Invalid key_id or plan_id"}), 400

    # Verify key belongs to user
    keys = get_user_keys(request.user_id)
    target_key = next((k for k in keys if k["key_id"] == key_id), None)
    if not target_key:
        return jsonify({"ok": False, "error": "Key not found or access denied"}), 404

    # Fetch plan by ID
    selected_plan = get_plan_by_id(plan_id)

    if not selected_plan:
        return jsonify({"ok": False, "error": "Plan not found"}), 404

    price = selected_plan["price"]
    months = selected_plan["months"]

    # Тот же класс бага, что и в /key/create (см. комментарий там) — правим
    # тем же способом: атомарное списание через deduct_from_balance() ДО
    # похода на XUI-панели, с возвратом денег при неудаче ниже.
    if not deduct_from_balance(request.user_id, price):
        return jsonify({"ok": False, "error": "Недостаточный баланс"}), 400

    # Calculate new expiry time
    current_expiry_str = target_key.get('expiry_date')
    if current_expiry_str:
        try:
            current_expiry = datetime.fromisoformat(current_expiry_str)
        except Exception:
            current_expiry = datetime.now()
    else:
        current_expiry = datetime.now()

    if current_expiry > datetime.now():
        new_expiry = current_expiry + timedelta(days=months)
    else:
        new_expiry = datetime.now() + timedelta(days=months)

    new_expiry_ms = int(new_expiry.timestamp() * 1000)

    # 1) Extend client on all hosts
    result = None
    try:
        result = xui_api.create_or_update_key_on_all_hosts_sync(
            email=target_key["key_email"],
            days_to_add=None,
            expiry_timestamp_ms=new_expiry_ms
        )
    except Exception as e:
        logger.error(f"Error extending key on XUI: {e}", exc_info=True)
        result = None

    if not result:
        adjust_user_balance(request.user_id, price)  # деньги уже списаны выше — вернуть
        return jsonify({"ok": False, "error": "Extension failed on VPN panels."}), 500

    # 2) Update key in database
    db_success = update_key_info(
        key_id,
        result.get("client_uuid") or target_key["xui_client_uuid"],
        result.get("expiry_timestamp_ms") or new_expiry_ms
    )
    
    if not db_success:
        adjust_user_balance(request.user_id, price)  # деньги уже списаны выше — вернуть
        return jsonify({"ok": False, "error": "Failed to update key in bot database"}), 500

    return jsonify({
        "ok": True,
        "key": {
            "key_id": key_id,
            "expiry_date": new_expiry.isoformat()
        }
    })


# ==========================================
# 💳 BILLING & TOP-UP ENDPOINTS
# ==========================================

@api_bp.route('/billing/topup', methods=['POST'])
@require_api_key
@require_user_auth
def api_billing_topup():
    data = request.get_json() or {}
    amount_val = data.get('amount')
    method = data.get('method') or 'yookassa'

    if not amount_val:
        return jsonify({"ok": False, "error": "Missing amount"}), 400

    try:
        amount = float(amount_val)
    except ValueError:
        return jsonify({"ok": False, "error": "Invalid amount format"}), 400

    if amount < 50:
        return jsonify({"ok": False, "error": "Minimum top-up amount is 50 RUB"}), 400

    user_id = request.user_id

    if method == 'yookassa':
        yookassa_shop_id = get_setting("yookassa_shop_id")
        yookassa_secret_key = get_setting("yookassa_secret_key")
        if not yookassa_shop_id or not yookassa_secret_key:
            return jsonify({"ok": False, "error": "YooKassa is not configured on the server"}), 500

        from yookassa import Configuration, Payment
        import uuid as uuid_lib

        Configuration.account_id = yookassa_shop_id
        Configuration.secret_key = yookassa_secret_key

        price_str = f"{amount:.2f}"
        customer_email = get_setting("receipt_email")
        receipt = None
        if customer_email and '@' in customer_email:
            receipt = {
                "customer": {"email": customer_email},
                "items": [{
                    "description": "Пополнение баланса",
                    "quantity": "1.00",
                    "amount": {"value": price_str, "currency": "RUB"},
                    "vat_code": "1"
                }]
            }

        payment_payload = {
            "amount": {"value": price_str, "currency": "RUB"},
            "confirmation": {"type": "redirect", "return_url": get_setting("domain") or "https://vpnonline.su"},
            "capture": True,
            "description": f"Пополнение баланса на {price_str} RUB",
            "metadata": {
                "user_id": user_id,
                "price": amount,
                "action": "top_up",
                "payment_method": "YooKassa"
            }
        }
        if receipt:
            payment_payload['receipt'] = receipt

        try:
            payment = Payment.create(payment_payload, uuid_lib.uuid4())
            pay_url = payment.confirmation.confirmation_url
            return jsonify({"ok": True, "pay_url": pay_url})
        except Exception as e:
            logger.error(f"Failed to create YooKassa billing payment: {e}", exc_info=True)
            return jsonify({"ok": False, "error": f"Failed to create YooKassa payment: {str(e)}"}), 500

    elif method == 'cryptobot':
        cryptobot_token = get_setting("cryptobot_token")
        if not cryptobot_token:
            return jsonify({"ok": False, "error": "CryptoBot is not configured on the server"}), 500

        host = "https://pay.cryptopay.me"
        if "testnet" in cryptobot_token.lower():
            host = "https://testnet-pay.cryptopay.me"

        payload_str = f"{user_id}:0:{amount}:top_up:None:None:None:None:CryptoBot"

        req_payload = {
            "amount": str(amount),
            "currency_type": "fiat",
            "fiat": "RUB",
            "accepted_assets": ["USDT", "TON", "BTC"],
            "payload": payload_str,
            "description": f"Пополнение баланса на {amount} RUB"
        }

        headers = {
            "Crypto-Pay-API-Token": cryptobot_token,
            "Content-Type": "application/json"
        }
        
        req = urllib.request.Request(
            f"{host}/api/createInvoice",
            data=json.dumps(req_payload).encode('utf-8'),
            headers=headers,
            method='POST'
        )
        try:
            with urllib.request.urlopen(req, timeout=10) as response:
                res_data = json.loads(response.read().decode('utf-8'))
                if res_data.get("ok"):
                    pay_url = res_data["result"]["pay_url"]
                    return jsonify({"ok": True, "pay_url": pay_url})
                else:
                    error_msg = res_data.get("error", {}).get("name", "Unknown error")
                    return jsonify({"ok": False, "error": f"CryptoBot error: {error_msg}"}), 500
        except urllib.error.HTTPError as e:
            try:
                res_data = json.loads(e.read().decode('utf-8'))
                error_msg = res_data.get("error", {}).get("name", str(e))
                return jsonify({"ok": False, "error": f"CryptoBot error: {error_msg}"}), 500
            except Exception:
                return jsonify({"ok": False, "error": f"CryptoBot HTTP error: {str(e)}"}), 500
        except Exception as e:
            logger.error(f"Failed to create CryptoBot invoice: {e}", exc_info=True)
            return jsonify({"ok": False, "error": str(e)}), 500

    else:
        return jsonify({"ok": False, "error": f"Unsupported payment method: {method}"}), 400


def verify_telegram_webapp_data(init_data: str, bot_token: str) -> dict | None:
    from urllib.parse import parse_qsl
    try:
        parsed_data = dict(parse_qsl(init_data))
        if 'hash' not in parsed_data:
            return None
            
        tg_hash = parsed_data.pop('hash')
        
        # Sort keys and join with newlines
        data_check_string = "\n".join(f"{k}={v}" for k, v in sorted(parsed_data.items()))
        
        # Compute HMAC signature using WebAppData secret key
        secret_key = hmac.new(b"WebAppData", bot_token.encode('utf-8'), hashlib.sha256).digest()
        calculated_hash = hmac.new(secret_key, data_check_string.encode('utf-8'), hashlib.sha256).hexdigest()
        
        if hmac.compare_digest(calculated_hash, tg_hash):
            user_data_str = parsed_data.get('user', '{}')
            return json.loads(user_data_str)
    except Exception as e:
        logger.error(f"Error verifying Telegram WebApp initData: {e}")
    return None

