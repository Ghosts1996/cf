"""
Обёртка над API панелей 3x-ui — v3, МУЛЬТИ-ХОСТ.

БАГ v2, который чинит этот файл: раньше был ОДИН набор XUI_BASE_URL/USERNAME/
PASSWORD в .env — то есть бэкенд физически мог говорить только с одной
панелью. Твой реальный backup БД показывает 6 строк в xui_hosts, у каждой
свои host_url/host_username/host_pass/host_inbound_id. Значит с одной
панелью приложение показало бы серверы и ключи только с ОДНОГО хоста из
шести — остальные локации были бы невидимы. Теперь каждый вызов принимает
конкретный `host: dict` (строку из xui_hosts), и сессионные cookie
кэшируются ОТДЕЛЬНО на каждый host_name, а не в одной глобальной переменной.

Сопоставление ключа в 3x-ui: раньше искали по `email == client_uuid`. В
реальной схеме vpn_keys есть ОТДЕЛЬНОЕ поле `key_email`, не совпадающее с
`xui_client_uuid` — значит сопоставлять в 3x-ui нужно по key_email (то же,
что использует и сам бот при создании клиента), а не по UUID.
"""
import time
import json
import uuid as uuid_lib
import httpx

# cookie сессии — отдельно на каждый host_name, чтобы не мешать хосты друг с другом
_session_cookies: dict[str, str] = {}

CACHE_TTL_SECONDS = 120  # «каждые 120 секунд проверять наличие новых стран»
_servers_cache: dict = {"data": None, "ts": 0.0}


async def _login(client: httpx.AsyncClient, host_name: str, username: str, password: str) -> str:
    resp = await client.post("/login", data={"username": username, "password": password})
    resp.raise_for_status()
    body = resp.json()
    if not body.get("success", False):
        raise RuntimeError(f"3x-ui login failed для хоста {host_name!r}: {body}")
    cookie = resp.cookies.get("3x-ui") or next(iter(resp.cookies), None)
    if not cookie:
        raise RuntimeError(
            f"Панель {host_name!r} не вернула cookie сессии — формат авторизации "
            "может отличаться на этом форке/версии панели."
        )
    _session_cookies[host_name] = cookie
    return cookie


async def _authed_request(host: dict, method: str, path: str, **kwargs) -> httpx.Response:
    """Общий helper: делает запрос к панели конкретного хоста, логинится при 401."""
    host_name = host["host_name"]
    base_url = host["host_url"].rstrip("/")
    username = host["host_username"]
    password = host["host_pass"]

    async with httpx.AsyncClient(base_url=base_url, timeout=15) as client:
        cookie = _session_cookies.get(host_name)
        if cookie:
            client.cookies.set("3x-ui", cookie)
        resp = await client.request(method, path, **kwargs)
        if resp.status_code == 401:
            cookie = await _login(client, host_name, username, password)
            client.cookies.set("3x-ui", cookie)
            resp = await client.request(method, path, **kwargs)
        resp.raise_for_status()
        return resp


async def get_inbounds(host: dict) -> list[dict]:
    resp = await _authed_request(host, "GET", "/panel/api/inbounds/list")
    data = resp.json()
    return data.get("obj", []) or []


def parse_server_from_inbound(host: dict, inbound: dict, ping_info: dict | None) -> dict:
    """
    Ожидаемый формат remark: "<ISO-код> <Название>", например "DE Frankfurt".
    Если у тебя remark назван иначе — поправь разбор здесь один раз, и все
    текущие и будущие локации на всех 6 хостах подхватятся автоматически.
    """
    remark = (inbound.get("remark") or host.get("host_name") or "").strip()
    parts = remark.split(" ", 1)
    country_code = parts[0][:2].upper() if parts and parts[0] else "??"
    name = parts[1] if len(parts) > 1 else (remark or f"Inbound {inbound.get('id')}")
    server = {
        "id": host["host_name"],
        "host_name": host["host_name"],
        "country_code": country_code,
        "name": name,
        "enabled": bool(inbound.get("enable", True)),
        "ping_ms": None,
        "jitter_ms": None,
        "download_mbps": None,
        "upload_mbps": None,
        "measured_at": None,
    }
    if ping_info and ping_info.get("ok"):
        server.update({
            "ping_ms": ping_info.get("ping_ms"),
            "jitter_ms": ping_info.get("jitter_ms"),
            "download_mbps": ping_info.get("download_mbps"),
            "upload_mbps": ping_info.get("upload_mbps"),
            "measured_at": str(ping_info.get("created_at")) if ping_info.get("created_at") else None,
        })
    return server


async def get_servers_cached(hosts: list[dict], speedtests: dict[str, dict]) -> list[dict]:
    """
    Список серверов со ВСЕХ хостов сразу, с TTL-кэшем 120 сек — по требованию
    «каждые 120 секунд проверять наличие новых стран». Если панель одного
    хоста недоступна — остальные хосты всё равно отдаются (частичный отказ
    не должен ронять весь список серверов).
    """
    now = time.time()
    if _servers_cache["data"] is not None and (now - _servers_cache["ts"]) < CACHE_TTL_SECONDS:
        return _servers_cache["data"]

    # v4: переиспользуем общий кэш инбаундов (см. get_all_inbounds_cached) —
    # раньше список серверов и статусы ключей дёргали панели независимо
    # друг от друга, удваивая нагрузку на 3x-ui при том, что данные одни
    # и те же в пределах одного TTL-окна.
    all_inbounds = await get_all_inbounds_cached(hosts)

    def _one_host(host: dict) -> list[dict]:
        inbounds = all_inbounds.get(host["host_name"], [])
        target_id = host.get("host_inbound_id")
        relevant = [i for i in inbounds if target_id is None or i.get("id") == target_id]
        ping_info = speedtests.get(host["host_name"])
        return [
            parse_server_from_inbound(host, i, ping_info)
            for i in relevant if i.get("enable", True)
        ]

    servers = [s for host in hosts for s in _one_host(host)]
    servers.sort(key=lambda s: (s["ping_ms"] is None, s["ping_ms"] or 0))
    _servers_cache["data"] = servers
    _servers_cache["ts"] = now
    return servers


async def get_client_stats(host: dict, key_email: str) -> dict | None:
    """Живой статус конкретного ключа. Сопоставление — по key_email (см. заголовок файла)."""
    try:
        inbounds = await get_inbounds(host)
    except Exception:
        return None
    return _find_in_inbounds(inbounds, host, key_email)


def _find_in_inbounds(inbounds: list[dict], host: dict, key_email: str) -> dict | None:
    target_id = host.get("host_inbound_id")
    for inbound in inbounds:
        if target_id is not None and inbound.get("id") != target_id:
            continue
        for stat in inbound.get("clientStats", []) or []:
            if stat.get("email") == key_email:
                return {
                    "enabled": bool(stat.get("enable", True)),
                    "up_bytes": stat.get("up", 0),
                    "down_bytes": stat.get("down", 0),
                    "expiry_time_ms": stat.get("expiryTime", 0),
                }
    return None  # ключ отключён/удалён в панели -> должен исчезнуть и в приложении


# ---------------------------------------------------------------- shared inbounds cache (v4)
# БАГ, который чинит этот блок: раньше `get_client_stats` делал ОТДЕЛЬНЫЙ
# запрос get_inbounds() к панели на КАЖДЫЙ ключ пользователя при каждом
# открытии экрана "Мои ключи". У пользователя с ключами на 3-4 локациях это
# 3-4 живых HTTP-похода (с возможным релогином на 401) на каждое обновление
# экрана — медленно и создаёт лишнюю нагрузку на все панели 3x-ui сразу.
# Теперь инбаунды всех хостов кэшируются ОДИН раз на TTL (см.
# CACHE_TTL_SECONDS) и переиспользуются и для списка серверов, и для
# статусов ключей.
#
# Также это устраняет более серьёзный баг v3: `vpn_keys.host_name` в
# реальной БД бота у ВСЕХ строк равен константе 'GLOBAL' (не имя хоста!) —
# проверено по реальному backup. Строка host_name НЕ является внешним
# ключом на xui_hosts.host_name, вопреки более ранней версии этого файла.
# Значит найти, на какой ИМЕННО панели живёт конкретный ключ, по
# vpn_keys.host_name невозможно. Вместо того чтобы гадать по суффиксу в
# key_email (ненадёжно и может разойтись с тем, как реально работает бот),
# ниже — честный перебор (fan-out): ищем key_email во ВСЕХ подключённых
# хостах и возвращаем тот, где он реально нашёлся. Дороже одного точного
# запроса, но не полагается на непроверенное предположение о схеме имён.
_inbounds_cache: dict = {"data": None, "ts": 0.0}


async def get_all_inbounds_cached(hosts: list[dict]) -> dict[str, list[dict]]:
    import asyncio

    now = time.time()
    if _inbounds_cache["data"] is not None and (now - _inbounds_cache["ts"]) < CACHE_TTL_SECONDS:
        return _inbounds_cache["data"]

    async def _one(host: dict) -> tuple[str, list[dict]]:
        try:
            return host["host_name"], await get_inbounds(host)
        except Exception:
            return host["host_name"], []  # хост временно недоступен — не роняем остальные

    results = await asyncio.gather(*[_one(h) for h in hosts])
    data = dict(results)
    _inbounds_cache["data"] = data
    _inbounds_cache["ts"] = now
    return data


async def find_client_any_host(hosts: list[dict], key_email: str) -> tuple[dict | None, dict | None]:
    """
    Ищет key_email во всех подключённых хостах сразу (см. комментарий выше).
    Возвращает (host, stats) хоста, где ключ реально найден, либо (None, None).
    """
    all_inbounds = await get_all_inbounds_cached(hosts)
    for host in hosts:
        inbounds = all_inbounds.get(host["host_name"], [])
        stats = _find_in_inbounds(inbounds, host, key_email)
        if stats is not None:
            return host, stats
    return None, None


def build_subscription_url(host: dict, key_email: str) -> str | None:
    base = (host.get("subscription_url") or "").rstrip("/")
    if not base:
        return None
    return f"{base}/{key_email}"


async def create_client(host: dict, key_email: str, days: int) -> dict:
    """
    Создаёт нового VLESS-клиента на конкретном хосте.

    ПРЕДПОЛОЖЕНИЕ (не проверено без доступа к твоей реальной панели —
    проверь на одном хосте вручную перед тем как включать на проде):
    POST /panel/api/inbounds/addClient, settings — JSON-строка с полем
    clients. Частый источник ошибок 400 при переносе между форками.
    """
    client_uuid = str(uuid_lib.uuid4())
    expiry_ms = int((time.time() + days * 86400) * 1000)
    inbound_id = host["host_inbound_id"]

    settings = json.dumps({
        "clients": [{
            "id": client_uuid,
            "email": key_email,  # сопоставление в get_client_stats идёт по key_email
            "enable": True,
            "expiryTime": expiry_ms,
            "limitIp": 0,
            "totalGB": 0,
        }]
    })
    resp = await _authed_request(
        host, "POST", "/panel/api/inbounds/addClient",
        json={"id": inbound_id, "settings": settings},
    )
    body = resp.json()
    if not body.get("success", False):
        raise RuntimeError(f"3x-ui addClient failed на хосте {host['host_name']!r}: {body}")

    return {
        "host_name": host["host_name"],
        "client_uuid": client_uuid,
        "key_email": key_email,
        "expires_at_ms": expiry_ms,
    }


async def extend_client(host: dict, client_uuid: str, key_email: str,
                         current_expiry_ms: int, days: int) -> int:
    base = max(current_expiry_ms, int(time.time() * 1000))
    new_expiry_ms = base + days * 86400 * 1000
    inbound_id = host["host_inbound_id"]

    settings = json.dumps({
        "clients": [{
            "id": client_uuid,
            "email": key_email,
            "enable": True,
            "expiryTime": new_expiry_ms,
        }]
    })
    resp = await _authed_request(
        host, "POST", f"/panel/api/inbounds/{inbound_id}/updateClient/{client_uuid}",
        json={"id": inbound_id, "settings": settings},
    )
    body = resp.json()
    if not body.get("success", False):
        raise RuntimeError(f"3x-ui updateClient failed на хосте {host['host_name']!r}: {body}")
    return new_expiry_ms
