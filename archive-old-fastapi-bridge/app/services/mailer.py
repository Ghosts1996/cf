"""
Отправка писем — v4.1: заменяет `print(...)` в auth.py на реальный SMTP.

Пока не знаю, чем именно у тебя отправляет почта сайт (PHP mail(), готовый
SMTP-провайдер типа Yandex/Mail.ru/SMTP.com, либо что-то через API) — если
пришлёшь этот кусок кода с сайта, подгоню шаблоны писем 1:1 (тема, текст,
оформление), чтобы у пользователя не было ощущения "два разных сервиса".
Пока сделал через стандартный `smtplib` (STARTTLS/SSL) — это должно
работать с ЛЮБЫМ SMTP: Яндекс 360, mail.ru, обычный почтовый ящик на
твоём же хостинге, SendGrid/Mailgun через их SMTP-relay и т.д. — нужно
только прописать хост/порт/логин/пароль в .env.

Почему asyncio.to_thread: smtplib — синхронная (блокирующая) библиотека.
Вызов её напрямую из async-роута заблокировал бы весь event loop FastAPI
на время соединения с почтовым сервером (обычно доли секунды, но под
нагрузкой это заметно) — все остальные запросы к бэкенду ждали бы. Выносим
в отдельный поток, чтобы event loop продолжал обрабатывать остальные
запросы параллельно.
"""
import os
import ssl
import asyncio
import smtplib
import logging
from email.message import EmailMessage

logger = logging.getLogger("vpnonline.mailer")

SMTP_HOST = os.getenv("SMTP_HOST", "")
SMTP_PORT = int(os.getenv("SMTP_PORT", "587"))
SMTP_USER = os.getenv("SMTP_USER", "")
SMTP_PASSWORD = os.getenv("SMTP_PASSWORD", "")
SMTP_FROM = os.getenv("SMTP_FROM", "noreply@vpnonline.su")
# Порт 465 = SSL с самого начала соединения (implicit TLS).
# Порт 587 (стандарт по умолчанию) = сначала обычное соединение, потом STARTTLS.
SMTP_USE_SSL = os.getenv("SMTP_USE_SSL", "false").lower() in ("1", "true", "yes")

BRAND_NAME = os.getenv("BRAND_NAME", "VPN onLine")


def is_configured() -> bool:
    return bool(SMTP_HOST and SMTP_USER and SMTP_PASSWORD)


def _send_sync(to_email: str, subject: str, text_body: str, html_body: str) -> None:
    msg = EmailMessage()
    msg["Subject"] = subject
    msg["From"] = f"{BRAND_NAME} <{SMTP_FROM}>"
    msg["To"] = to_email
    msg.set_content(text_body)
    msg.add_alternative(html_body, subtype="html")

    context = ssl.create_default_context()
    if SMTP_USE_SSL:
        with smtplib.SMTP_SSL(SMTP_HOST, SMTP_PORT, timeout=15, context=context) as server:
            server.login(SMTP_USER, SMTP_PASSWORD)
            server.send_message(msg)
    else:
        with smtplib.SMTP(SMTP_HOST, SMTP_PORT, timeout=15) as server:
            server.starttls(context=context)
            server.login(SMTP_USER, SMTP_PASSWORD)
            server.send_message(msg)


async def send_email(to_email: str, subject: str, text_body: str, html_body: str) -> None:
    """
    Не поднимает исключение наружу в вызывающий роут пользователя — ошибка
    SMTP не должна превращаться в "500 Internal Server Error" для человека,
    который просто пытается зарегистрироваться (это UX-катастрофа: он не
    поймёт, что делать). Вместо этого пишем в лог, чтобы ты это увидел и
    поправил конфигурацию/провайдера, а пользователь просто попробует
    "отправить код ещё раз" чуть позже.
    """
    if not is_configured():
        logger.warning(
            "SMTP не настроен (SMTP_HOST/USER/PASSWORD пустые в .env) — "
            "письмо на %s НЕ отправлено. Тема: %s", to_email, subject,
        )
        return
    try:
        await asyncio.to_thread(_send_sync, to_email, subject, text_body, html_body)
    except Exception:
        logger.exception("Не удалось отправить письмо на %s", to_email)


def _wrap_html(title: str, body_html: str, show_title: bool = True) -> str:
    title_html = f'<h2 style="margin:0 0 12px;font-size:19px;">{title}</h2>' if show_title else ""
    return f"""\
<!doctype html><html><body style="margin:0;padding:0;background:#05040a;font-family:Arial,Helvetica,sans-serif;">
<table width="100%" cellpadding="0" cellspacing="0" style="background:#05040a;padding:32px 0;">
<tr><td align="center">
<table width="420" cellpadding="0" cellspacing="0" style="background:#120b22;border:1px solid rgba(255,255,255,0.08);border-radius:16px;overflow:hidden;">
<tr><td style="padding:28px 28px 4px;">
<span style="color:#a855f7;font-size:22px;font-weight:800;">{BRAND_NAME}</span>
</td></tr>
<tr><td style="padding:8px 28px 28px;color:#f1ecff;">
{title_html}
{body_html}
</td></tr>
<tr><td style="padding:16px 28px;color:#9d93bd;font-size:11.5px;border-top:1px solid rgba(255,255,255,0.06);">
Если это были не вы — просто проигнорируйте это письмо.
</td></tr>
</table>
</td></tr>
</table>
</body></html>"""


async def send_registration_code(to_email: str, code: str) -> None:
    """Текст письма — 1:1 копия реального письма сайта (см. присланный
    скриншот), только с "VPN Online Shop" -> "VPN onLine" (фирменное
    написание бренда без "Shop")."""
    subject = f"Код подтверждения регистрации — {BRAND_NAME}"
    text = (
        f"Здравствуйте!\n\n"
        f"Вы регистрируетесь в личном кабинете {BRAND_NAME}. "
        f"Пожалуйста, используйте следующий код подтверждения:\n\n"
        f"{code}\n\n"
        f"Код действителен в течение 10 минут. Если вы не запрашивали этот код, "
        f"просто проигнорируйте это письмо."
    )
    html = _wrap_html(
        BRAND_NAME,
        f'<p style="color:#c9c1e8;font-size:14px;">Здравствуйте!</p>'
        f'<p style="color:#c9c1e8;font-size:14px;">Вы регистрируетесь в личном кабинете {BRAND_NAME}. '
        f'Пожалуйста, используйте следующий код подтверждения:</p>'
        f'<p style="font-size:32px;font-weight:800;letter-spacing:0.15em;color:#fff;margin:16px 0;text-align:center;">{code}</p>'
        f'<p style="color:#9d93bd;font-size:12.5px;">Код действителен в течение 10 минут. '
        f'Если вы не запрашивали этот код, просто проигнорируйте это письмо.</p>',
        show_title=False,
    )
    await send_email(to_email, subject, text, html)


async def send_password_reset_code(to_email: str, code: str) -> None:
    subject = f"Восстановление пароля — {BRAND_NAME}"
    text = (
        f"Здравствуйте!\n\n"
        f"Вы запросили сброс пароля от личного кабинета {BRAND_NAME}. "
        f"Пожалуйста, используйте следующий код для подтверждения:\n\n"
        f"{code}\n\n"
        f"Код действителен в течение 10 минут. Если вы не запрашивали сброс пароля, "
        f"просто проигнорируйте это письмо."
    )
    html = _wrap_html(
        BRAND_NAME,
        f'<p style="color:#c9c1e8;font-size:14px;">Здравствуйте!</p>'
        f'<p style="color:#c9c1e8;font-size:14px;">Вы запросили сброс пароля от личного кабинета {BRAND_NAME}. '
        f'Пожалуйста, используйте следующий код для подтверждения:</p>'
        f'<p style="font-size:32px;font-weight:800;letter-spacing:0.15em;color:#fff;margin:16px 0;text-align:center;">{code}</p>'
        f'<p style="color:#9d93bd;font-size:12.5px;">Код действителен в течение 10 минут. '
        f'Если вы не запрашивали сброс пароля, просто проигнорируйте это письмо.</p>',
        show_title=False,
    )
    await send_email(to_email, subject, text, html)
