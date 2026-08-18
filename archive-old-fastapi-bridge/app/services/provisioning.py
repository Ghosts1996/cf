"""
Общая логика выдачи/продления ключа сразу на всех локациях ("бандл") — v4.

ПОДТВЕРЖДЕНО ПО РЕАЛЬНЫМ ДАННЫМ (backup БД, не предположение): одна
покупка = несколько строк vpn_keys, по одной на каждую локацию (см. разбор
в routes/keys.py — сгруппированные `user@bot.local` / `user-nl@bot.local` /
`user-us@bot.local`). Версии до v4 создавали ключ только на ОДНОМ хосте,
который пользователь должен был выбрать сам на экране "Серверы" — это не
совпадает с тем, как реально работает сервис (сайт прямо говорит: "Единый
VPN ключ включает в себя доступ сразу к 4 высокоскоростным локациям...
с автоматической балансировкой").

ДОПУЩЕНИЕ, которое стоит проверить на реальной панели перед продом (не
может быть проверено без доступа к твоей инфраструктуре): суффикс локации
в key_email для НОВЫХ ключей здесь — country_code, разобранный из remark
инбаунда (тот же разбор, что уже используется для списка серверов),
например "-de"/"-nl"/"-us"/"-ru". Это совпадает с фактическим суффиксом у
существующих ключей для Нидерландов (-nl) и США (-us) в твоём backup. Если
твой бот использует другой алгоритм генерации суффиксов для новых ключей —
эта функция не обязана совпадать с ним побайтово, потому что ЧТЕНИЕ
(routes/keys.py) не полагается на суффикс вообще — оно ищет ключ честным
перебором по всем панелям (xui_client.find_client_any_host). Разойтись
может только "красивое" отображаемое имя, не сама работоспособность ключа.

ТРЕБОВАНИЕ ПОЛЬЗОВАТЕЛЯ ("если добавил страну в VPN — приложение должно
само её увидеть и добавить"): бандл строится из ВСЕХ хостов, которые есть
в xui_hosts НА МОМЕНТ покупки — жёстко зашитого списка "только эти 4" нет.
Значит только что добавленная 7-я локация сразу участвует в новых покупках
без единой правки кода — не только в списке серверов (это уже работало
раньше), но и в выдаче ключей.
"""
import re
import time
import datetime as dt

from app.services import shop_db, xui_client


async def _host_suffix(host: dict, inbounds_by_host: dict[str, list[dict]]) -> str:
    inbounds = inbounds_by_host.get(host["host_name"], [])
    target_id = host.get("host_inbound_id")
    relevant = next((i for i in inbounds if target_id is None or i.get("id") == target_id), None)
    if relevant:
        server = xui_client.parse_server_from_inbound(host, relevant, None)
        code = (server.get("country_code") or "").lower()
        if code and code != "??":
            return code
    # Панель временно недоступна прямо сейчас — грубая запасная заглушка
    # (латинские буквы host_name, если они есть), чтобы не блокировать всю
    # покупку из-за одного офлайн-хоста. host_name у тебя обычно на
    # кириллице с эмодзи-флагом — транслитерации здесь сознательно нет,
    # это просто отличимый ярлык, не влияющий на работоспособность ключа.
    fallback = re.sub(r"[^a-zA-Z]", "", host["host_name"])[:2].lower()
    return fallback or "xx"


async def provision_bundle(identity: str, base_key_email: str, days: int) -> dict:
    """
    Выдаёт (или продлевает, если уже существует) ключ на КАЖДОМ активном
    хосте сразу. Частичный отказ по одному хосту (панель временно
    недоступна/ошибка API) не должен блокировать выдачу на остальных
    локациях — пользователь получит доступ туда, где выдача удалась, и
    ошибка по остальным будет видна в ответе для логирования/поддержки.

    Возвращает {"issued": [...], "failed": [...]}.
    Бросает RuntimeError, только если НЕ удалось выдать ключ НИ НА ОДНОМ
    хосте — в этом случае платить/списывать баланс не за что.
    """
    hosts = await shop_db.get_xui_hosts()
    if not hosts:
        raise RuntimeError("В xui_hosts нет ни одного сервера — нечего выдавать")

    inbounds_by_host = await xui_client.get_all_inbounds_cached(hosts)
    existing_rows = await shop_db.get_user_key_rows(identity)

    issued: list[dict] = []
    failed: list[dict] = []

    for host in hosts:
        suffix = await _host_suffix(host, inbounds_by_host)
        key_email = f"{base_key_email}-{suffix}"
        try:
            existing = next((r for r in existing_rows if r["key_email"] == key_email), None)
            if existing:
                current_expiry_ms = (
                    int(existing["expiry_date"].timestamp() * 1000)
                    if existing["expiry_date"] else int(time.time() * 1000)
                )
                new_expiry_ms = await xui_client.extend_client(
                    host, existing["xui_client_uuid"], key_email, current_expiry_ms, days
                )
                await shop_db.update_key_expiry(
                    existing["key_id"], dt.datetime.fromtimestamp(new_expiry_ms / 1000, tz=dt.timezone.utc)
                )
                issued.append({"host_name": host["host_name"], "key_email": key_email, "mode": "extended"})
            else:
                created = await xui_client.create_client(host, key_email, days)
                await shop_db.insert_key_row(
                    identity, host["host_name"], created["client_uuid"], key_email,
                    dt.datetime.fromtimestamp(created["expires_at_ms"] / 1000, tz=dt.timezone.utc),
                )
                issued.append({"host_name": host["host_name"], "key_email": key_email, "mode": "created"})
        except Exception as e:  # noqa: BLE001 — намеренно широкий catch: один упавший хост не должен рушить весь бандл
            failed.append({"host_name": host["host_name"], "error": str(e)})

    if not issued:
        raise RuntimeError(f"Не удалось выдать ключ ни на одном хосте: {failed}")
    return {"issued": issued, "failed": failed}
