"""
Список серверов = агрегация ВСЕХ панелей 3x-ui из таблицы xui_hosts бота,
плюс данные пинга/скорости из host_speedtests (которые бот уже собирает —
не измеряется заново, чтобы не создавать лишний фоновый трафик).

Обновление — раз в 120 секунд (см. xui_client.CACHE_TTL_SECONDS), как в
требовании «приложение должно... каждые 120 секунд проверять наличие новых
стран». Список сортируется по пингу — сервер с наименьшим пингом идёт первым
(приложение может пометить его как «рекомендуемый»).
"""
from fastapi import APIRouter, HTTPException
from app.services import xui_client, shop_db

router = APIRouter()


@router.get("")
async def list_servers():
    try:
        hosts = await shop_db.get_xui_hosts()
    except Exception as e:
        raise HTTPException(502, f"Не удалось прочитать список хостов из БД бота: {e}")

    if not hosts:
        return []

    speedtests = await shop_db.get_latest_speedtests()
    return await xui_client.get_servers_cached(hosts, speedtests)
