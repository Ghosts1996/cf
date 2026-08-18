# Разворачивание на реальном сервере — по шагам

Это единственная часть, которую физически нельзя выполнить в среде агента
(нет сети/доступа к твоему серверу) — но каждый шаг конкретный, без "додумай сам".

## 1. Подготовка

```bash
sudo useradd --system --no-create-home vpnonline-api
sudo mkdir -p /opt/vpnonline-backend
sudo chown vpnonline-api:vpnonline-api /opt/vpnonline-backend
```

Скопируй содержимое `backend/` в `/opt/vpnonline-backend/` (например `scp -r backend/* user@server:/opt/vpnonline-backend/`).

## 2. Виртуальное окружение и зависимости

```bash
cd /opt/vpnonline-backend
python3 -m venv venv
./venv/bin/pip install -r requirements.txt
```

## 3. `.env`

```bash
cp .env.example .env
nano .env
```

Обязательно заполни:
- `DATABASE_URL` — путь к ТОЙ ЖЕ БД, что использует бот. Если это тот же
  SQLite-файл, что в `db-backup-*.zip`: `sqlite+aiosqlite:////абсолютный/путь/users.db`
- `JWT_SECRET` — сгенерируй: `openssl rand -hex 32`
- `YOOKASSA_SHOP_ID` / `YOOKASSA_SECRET_KEY` — из личного кабинета ЮKassa
- `CRYPTOBOT_TOKEN` — из @CryptoBot → Crypto Pay → My Apps
- `CORS_ORIGINS` — домены, с которых реально будет идти обращение
  (сайт/Mini App), через запятую

**Панели 3x-ui отдельно указывать не нужно** — backend читает их прямо из
таблицы `xui_hosts` в той же БД.

## 4. Права на файл БД

Если БД — SQLite-файл бота, `vpnonline-api` должен иметь право на чтение
**и запись** (создаются/обновляются ключи, заказы, транзакции):

```bash
sudo chown :vpnonline-api /путь/к/users.db
sudo chmod 660 /путь/к/users.db
```

Также добавь путь к файлу БД в `ReadWritePaths=` в
`deploy/vpnonline-backend.service`, если он лежит вне `/opt/vpnonline-backend`
(там стоит `ProtectSystem=strict`, который иначе запретит запись).

## 5. systemd

```bash
sudo cp deploy/vpnonline-backend.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now vpnonline-backend
sudo systemctl status vpnonline-backend
journalctl -u vpnonline-backend -f   # смотреть логи вживую
```

Если `_validate_env()` найдёт незаполненные переменные — процесс упадёт
сразу при старте с понятным сообщением в логах, а не будет молча отвечать
500-ками пользователям.

## 6. nginx + HTTPS

```bash
sudo apt install certbot python3-certbot-nginx
sudo cp deploy/nginx-vpnonline-api.conf /etc/nginx/sites-available/vpnonline-api
sudo ln -s /etc/nginx/sites-available/vpnonline-api /etc/nginx/sites-enabled/
sudo certbot --nginx -d api.vpnonline.su
sudo nginx -t && sudo systemctl reload nginx
```

Добавь зону rate-limit в `/etc/nginx/nginx.conf` (внутри `http {}`), если
её там ещё нет:
```
limit_req_zone $binary_remote_addr zone=vpnonline_api:10m rate=20r/s;
```

## 7. Проверка перед тем, как подключать реальные платежи

```bash
curl https://api.vpnonline.su/health
curl https://api.vpnonline.su/v1/servers        # должны прийти все 6 хостов
curl https://api.vpnonline.su/v1/plans          # 4 тарифа из твоей таблицы plans
```

Затем — **вручную, на одном хосте**, проверь `create_client`/`extend_client`
в `xui_client.py` (это единственное место, помеченное как непроверенное
предположение по формату API 3x-ui — см. CHANGELOG_v3.md). Только после
этого подключай вебхуки YooKassa/CryptoBot к продовым ключам.

## 8. Webhook URL у провайдеров

- YooKassa (личный кабинет → Настройки → HTTP-уведомления):
  `https://api.vpnonline.su/v1/webhooks/yookassa`
- CryptoBot (@CryptoBot → Crypto Pay → My Apps → Webhooks):
  `https://api.vpnonline.su/v1/webhooks/cryptobot`
