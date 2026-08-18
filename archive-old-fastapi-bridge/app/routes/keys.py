"""
Ключи пользователя — v4, ПЕРЕДЕЛАНО под реальную схему.

КРИТИЧЕСКАЯ НАХОДКА (проверено по реальному backup БД, не предположение):
во ВСЕХ строках vpn_keys поле host_name равно константе 'GLOBAL' — это не
внешний ключ на xui_hosts.host_name, вопреки более ранней версии этого
файла. Старый код делал `hosts.get(row["host_name"])`, что при host_name==
'GLOBAL' ВСЕГДА возвращало None — то есть `active_in_panel` было бы `false`,
а `subscription_url` — `null` для АБСОЛЮТНО ЛЮБОГО ключа в проде. Это самый
серьёзный найденный баг: раздел "Мои ключи" физически не мог показать ни
одной живой ссылки ни одному пользователю.

Реальная структура (проверено по данным, не по документации): одна покупка
у тебя создаёт НЕСКОЛЬКО строк vpn_keys — по одной на каждую локацию
бандла (например `user@bot.local`, `user-nl@bot.local`, `user-us@bot.local`)
— это и есть "единый ключ на 4 локации с автобалансировкой" с сайта.
Экземпляры на разных устройствах — через `_devN` в email и общий
`parent_key_id`.

Что делает этот файл:
1. Группирует строки пользователя в "подписки" по общему префиксу email
   (эвристика уровня отображения — если она не сработает для каких-то
   экзотических email, каждая строка просто покажется отдельной картой,
   без потери данных).
2. Для КАЖДОЙ строки реальный хост ищется честным перебором (fan-out) по
   всем подключённым панелям 3x-ui — см. xui_client.find_client_any_host —
   а не угадывается по суффиксу, чтобы не полагаться на непроверенное
   предположение об именах.
"""
import re
from fastapi import APIRouter, Depends
from app.services import shop_db, xui_client
from app.auth_deps import get_current_user

router = APIRouter()

# Известные суффиксы локаций и добавочных устройств — используется ТОЛЬКО
# для визуальной группировки строк в одну карточку "подписки", не для
# определения реального хоста (это делает fan-out, см. выше). Если у тебя
# появится локация с суффиксом длиннее 3 букв — группировка на неё просто
# не сработает, ключ покажется отдельной карточкой (без потери данных).
_GROUP_RE = re.compile(r"^(?P<base>.+?)(?:-[a-z]{2,3})?(?:_dev\d+)?$")


def _group_key(key_email: str) -> str:
    local = key_email.split("@")[0]
    m = _GROUP_RE.match(local)
    return m.group("base") if m else local


@router.get("")
async def list_keys(user: dict = Depends(get_current_user)):
    rows = await shop_db.get_user_key_rows(user["sub"])
    if not rows:
        return []

    hosts = await shop_db.get_xui_hosts()
    hosts_by_name = {h["host_name"]: h for h in hosts}

    result = []
    for row in rows:
        # v4: сначала пробуем host_name КАК ЕСТЬ — вдруг это ключ, созданный
        # уже новым бэкендом (см. orders.py v4), который пишет реальное имя
        # хоста, а не 'GLOBAL'. Если не совпало ни с одним подключённым
        # хостом (в т.ч. исторический 'GLOBAL') — честный перебор.
        host = hosts_by_name.get(row["host_name"])
        stats = await xui_client.get_client_stats(host, row["key_email"]) if host else None
        if host is None or stats is None:
            found_host, found_stats = await xui_client.find_client_any_host(hosts, row["key_email"])
            if found_host is not None:
                host, stats = found_host, found_stats

        result.append({
            "key_id": row["key_id"],
            "group_id": _group_key(row["key_email"]),
            "host_name": host["host_name"] if host else row["host_name"],
            "key_email": row["key_email"],
            "subscription_url": (
                xui_client.build_subscription_url(host, row["key_email"]) if host else row.get("subscription_url")
            ),
            "expires_at": str(row["expiry_date"]) if row["expiry_date"] else None,
            "devices_limit": row["devices_limit"],
            "device_number": row["device_number"],
            "active_in_panel": stats is not None,
            "live_stats": stats,
        })
    return result
