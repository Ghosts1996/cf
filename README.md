# VPN onLine — приложение (v5, объединённая версия)

Этот README — актуальная точка входа. Собран из двух прошлых веток работы:
`vpnonline-project-v4` (UI, навигация, реальный VLESS-туннель, CI/CD) и
`vpnonline-security-fixes` (аудит реального кода бота + переписанный
`api_client.dart` под НАСТОЯЩИЙ контракт API). Ниже — что было объединено,
что реально готово, и что нужно сделать тебе руками (секреты, которые я
не могу знать или придумать за тебя).

## Главное изменение архитектуры

Раньше приложение стучалось в отдельный придуманный FastAPI-мост
(`archive-old-fastapi-bridge/`, пути вида `/orders`, `/balance` —
их не существует на сервере). Аудит реального кода бота показал: у тебя
**уже есть** рабочий Flask API прямо в shopbot
(`shopbot/src/shop_bot/webhook_server/api.py`, `/api/v1/...`) — регистрация,
логин, профиль, ключи, тарифы, покупка, пополнение баланса. Приложение
теперь стучится ТУДА напрямую (`https://api.vpnonline.shop/api/v1`).
Старый FastAPI-мост убран в `archive-old-fastapi-bridge/` — **не разворачивай
его**, оставлен только для истории.

## Состав проекта

```
vpnonline-app/
├── app/                        — Flutter-приложение (см. app/lib/screens)
├── backend-patch/              — 2 файла для замены в твоём shopbot:
│   ├── api.py                  — с исправлениями безопасности (см. REPORT.md)
│   ├── database.py             — с исправлениями безопасности
│   ├── REPORT.md               — подробный отчёт аудита (что было не так, доказательства)
│   └── ENV_ADDITIONS.env       — 3 переменные, которые нужно добавить в .env бота
└── archive-old-fastapi-bridge/ — устаревший мост, НЕ деплоить (см. его README.md)
```

## Что реально сделано в этом объединении

- `app/lib/services/api_client.dart` — заменён на версию, сверенную построчно
  с реальным `api.py` (реальные пути, реальные поля ответов, реальный
  механизм токена).
- Экраны `auth_screen.dart`, `keys_screen.dart`, `plans_screen.dart` — уже
  были переписаны под новый клиент в прошлой сессии, взяты как есть.
- Экраны `menu_screen.dart`, `referral_screen.dart`, `servers_screen.dart`,
  `connect_screen.dart` — **я дописал в этом ответе**: они ещё вызывали
  старые несуществующие методы (`getBalance()`, `getServers()`,
  `getReferralInfo()`, `measureBackendLatencyMs()`) и ожидали поля, которых
  нет в реальном API (`active_in_panel`, `subscription_url`, `devices_used`).
  Переписаны на `getProfile()`, `getHosts()`, `getKeys()` с реальными
  полями (`expiry_date`, `connection_string`, `devices_limit`).
- `main.dart` — добавлен обязательный `ApiClient.init()` перед первым
  использованием (новый клиент — синглтон с явной инициализацией, без
  этого шага приложение падало бы на первом экране).
- `.github/workflows/build-android.yml` — раньше собирал APK вообще без
  API-ключа (`--dart-define` не передавался). Добавил передачу
  `SHOPBOT_API_KEY` и `API_BASE_URL` из GitHub Secrets.
- `tunnel_service.dart` — `_fetchProfile()` теперь понимает и готовую
  `vless://`-ссылку, и URL подписки 3x-ui (см. предупреждение ниже).
- Синтаксическая проверка: `backend-patch/api.py` и `database.py`
  компилируются (`python3 -m py_compile`) без ошибок; все `.dart`-файлы
  проверены на баланс скобок; все YAML (`pubspec.yaml`, workflow-файлы)
  прошли `yaml.safe_load`.

## Единственное настоящее допущение, которое осталось

`connection_string` в ответе `/user/keys` формирует функция
`xui_api.get_key_details_from_host_sync()` в бэкенде бота — её исходный код
не входил ни в один из присланных файлов (только `api.py`/`database.py`).
Я не знаю точно, отдаёт ли она готовую `vless://`-ссылку или URL подписки
3x-ui, который сначала нужно скачать. `tunnel_service.dart` сейчас пробует
оба варианта по префиксу строки. Если после первого реального теста
подключение не работает — открой `xui_api.py` в исходниках бота и посмотри,
что реально лежит в `connection_string`, поправь `_fetchProfile()` под это.

## Что я поправил по твоему тесту от 13.08.2026

- **Ошибка "Unauthorized: Invalid or missing API key" на экране входа** —
  это была не ошибка логина, а то, что твоя сборка APK не передавала
  `SHOPBOT_API_KEY` вообще (см. п.4 ниже — Secret не был задан). Теперь
  ключ прописан значением по умолчанию прямо в `app/lib/main.dart` — сборка
  работает без обязательных флагов. Но для этого тот же ключ должен быть
  и в `.env` сервера (см. п.2 — `ENV_ADDITIONS.env`), иначе сервер всё
  равно ответит той же ошибкой уже по своей причине.
- **Иконка приложения** — заменена на щит в фирменных цветах
  (`#b026ff → #e042e0` на глубоко-чёрном фоне, low-poly грани, как у
  твоего лого). Источник — `app/assets/icon/`, генерация встроена в
  `pubspec.yaml` (`flutter_launcher_icons`) и в CI
  (`.github/workflows/build-android.yml`) — применится сама при
  следующей сборке, руками ничего сохранять по папкам `mipmap/` не нужно.
- **Платёжные ключи** (YooKassa, CryptoBot) — записаны в
  `backend-patch/set_payment_settings.py`, см. п.1.1 ниже. Это не .env, а
  БД бота — важно не перепутать, куда их вписывать.

## Что нужно сделать тебе — чек-лист

**1. Применить backend-патч (на сервере, где крутится shopbot):**
```bash
cp backend-patch/api.py      /path/to/shopbot/src/shop_bot/webhook_server/api.py
cp backend-patch/database.py /path/to/shopbot/src/shop_bot/webhook_server/database.py
```
Сделай `git diff` перед коммитом — это полные файлы, а не патчи, поэтому
если ты после `vpnonline-security-fixes` успел что-то ещё поменять в этих
двух файлах вручную, эти правки нужно перенести отдельно.

**1.1. Платёжные настройки (YooKassa, CryptoBot).** Они хранятся не в
`.env`, а в таблице `bot_settings` самой БД (см. `database.py` ->
`get_setting()`/`update_setting()`) — обычно их вводят через
админ-панель бота в Telegram. Я записал присланные тобой значения в
`backend-patch/set_payment_settings.py` — один раз выполни на сервере:
```bash
python3 backend-patch/set_payment_settings.py /path/to/shopbot/users.db
```
Если эти значения у тебя уже были настроены через админ-панель — скрипт
их просто перезапишет тем же (или новым, если ты их сменил) значением,
это безопасно. После запуска — можешь удалить сам скрипт с сервера,
секреты в БД уже сохранены.

**2. Добавить переменные в `.env` бота** — см. `backend-patch/ENV_ADDITIONS.env`:
- `SHOPBOT_API_KEY` — уже сгенерирован (случайная строка), просто скопируй.
- `GMAIL_APP_PASSWORD` — **обязательно новый**, старый был в открытом коде
  (см. `REPORT.md`, п.1) и считается скомпрометированным. Отзови в Google
  Account → Security → App Passwords, создай новый.
- `GMAIL_USER` — уже известен (`VPNonLineRoBot@gmail.com`), вписан.

**3. Перезапустить бота**, чтобы подхватились новые `api.py`/`database.py`/`.env`.

**4. GitHub Secret больше НЕ обязателен** — ключ уже вписан значением по
умолчанию в `app/lib/main.dart`, сборка работает и без него. Задавать
`SHOPBOT_API_KEY`/`API_BASE_URL` в Settings → Secrets and variables →
Actions имеет смысл только если захочешь собрать сборку под другой
ключ/домен, не трогая исходники.

**5. Собрать APK** — либо через GitHub Actions (workflow "Build Android
APK"), либо локально:
```bash
flutter build apk --release \
  --dart-define=SHOPBOT_API_KEY=<ключ из п.2> \
  --dart-define=API_BASE_URL=https://api.vpnonline.shop/api/v1
```

**6. Первый реальный тест** (этого я сделать не могу — нет ни Flutter SDK,
ни сети в песочнице, где я работаю):
- Регистрация нового пользователя → должен прийти код на email.
- Логин существующим аккаунтом с сайта.
- Экран "Мои ключи" → покупка тестового тарифа → появление ключа.
- Экран "Подключение" → реальный VLESS-туннель (см. допущение выше про
  `connection_string` — вероятнее всего первое, что придётся донастроить).

## Секреты, которых у меня никогда не было и я не мог их вписать

`YOOKASSA_SHOP_ID`/`YOOKASSA_SECRET_KEY`, `CRYPTOBOT_TOKEN`,
`HELEKET_MERCHANT_ID`/`HELEKET_API_KEY`, `DATABASE_URL` — они не нужны
новому патчу напрямую (см. выше — `backend-patch` использует уже
настроенное окружение бота), но если у тебя в текущем `.env` бота
какого-то из них не хватает, `billing/topup` не заработает. Это не
что-то, что я забыл вписать — я физически не располагаю этими значениями.

## Остальная документация (не менялась в этом объединении)

- `SECURITY.md` — более ранний аудит уязвимостей уровня приложения.
- `CHANGELOG_v2.md` / `CHANGELOG_v3.md` / `CHANGELOG_v4.md` — история
  предыдущих итераций.
- `app/NATIVE_SETUP.md` — платформенная настройка VPN-туннеля
  (App Group/Network Extension на iOS/macOS, xray.exe на Windows) —
  не может быть сделана только правкой `.dart`-файлов.
