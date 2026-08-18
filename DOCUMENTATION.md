# VPNonLine — техническая документация проекта

> Актуально на: сборка репозитория из `vpn-main-fixed.zip` + правки sing-box
> 1.13.0 / CI-подписи из этого чата. Документ собран напрямую по коду
> (не по старым описаниям в README/CHANGELOG — там местами есть устаревшие
> утверждения, см. раздел [«Расхождения со старыми README/CHANGELOG»](#расхождения-со-старыми-readmechangelog)).

## Содержание

1. [Обзор](#обзор)
2. [Архитектура](#архитектура)
3. [Структура репозитория](#структура-репозитория)
4. [Технологический стек](#технологический-стек)
5. [Клиентское приложение (Flutter)](#клиентское-приложение-flutter)
6. [Backend-контракт API](#backend-контракт-api)
7. [VPN-туннель: sing-box](#vpn-туннель-sing-box)
8. [Секреты и конфигурация](#секреты-и-конфигурация)
9. [CI/CD](#cicd)
10. [Безопасность — сводка](#безопасность--сводка)
11. [Установка и разработка](#установка-и-разработка)
12. [Деплой релиза — чек-лист](#деплой-релиза--чек-лист)
13. [Известные ограничения](#известные-ограничения)
14. [Troubleshooting](#troubleshooting)
15. [Расхождения со старыми README/CHANGELOG](#расхождения-со-старыми-readmechangelog)

---

## Обзор

**VPNonLine** — мобильный клиент (Flutter, Android в приоритете) для
коммерческого VPN-сервиса на протоколе VLESS/Reality. Пользователь
регистрируется по email, покупает тариф за баланс, получает ключ
(VLESS-ссылку или URL подписки 3x-ui) и подключается через встроенный
sing-box-туннель. Оплата баланса — YooKassa и CryptoBot. Распространение
ключей и сама панель управления хостами (3x-ui) обслуживаются отдельным
сервером — **shopbot** (Telegram-бот с встроенным Flask API), который не
входит в этот репозиторий, только два файла-патча к нему лежат в
`backend-patch/`.

Проект — не with-scratch разработка, а результат нескольких итераций
аудита и правок поверх уже существующего рабочего сервиса
(`api.vpnonline.shop`, бот в Telegram, панели 3x-ui). Отсюда обилие
комментариев в коде вида «было / стало / доказательство» — это
осознанный стиль проекта, документирующий, что именно было проверено по
реальному бэкенду, а что — предположение.

## Архитектура

```
┌─────────────────────┐      HTTPS + X-API-Key + Bearer JWT      ┌──────────────────────────┐
│  Flutter-приложение  │ ───────────────────────────────────────▶│  shopbot (Flask API)      │
│  (этот репозиторий,  │◀─────────────────────────────────────── │  /api/v1/...              │
│  app/)               │        JSON (см. раздел 6)               │  api.vpnonline.shop        │
└──────────┬───────────┘                                          └──────────┬────────────────┘
           │                                                                  │
           │ VLESS+Reality (полученный из /user/keys                         │ управляет
           │ connection_string, напрямую или через                           ▼
           │ подписку 3x-ui)                                        ┌──────────────────┐
           ▼                                                        │  3x-ui панели      │
┌──────────────────────┐                                            │  (6 хостов/локаций)│
│  sing-box core        │ ◀── туннелирует пользовательский трафик   └──────────────────┘
│  (flutter_singbox_    │
│  client, Android-only)│
└───────────────────────┘
```

Ключевой момент архитектуры (см. `README.md`): раньше приложение было
написано под **придуманный** отдельный FastAPI-мост
(`archive-old-fastapi-bridge/`, пути вида `/orders`, `/balance`) — он не
существует на сервере и **не должен разворачиваться**. Реальный контракт
— это уже работающий Flask Blueprint `/api/v1/...` внутри самого shopbot
(`shopbot/src/shop_bot/webhook_server/api.py`, файл вне этого репозитория,
патчится через `backend-patch/`).

## Структура репозитория

```
.
├── app/                          Flutter-приложение (единственное, что собирает CI)
│   ├── lib/
│   │   ├── main.dart             Точка входа, ApiClient.init(), тема статус-бара
│   │   ├── theme.dart            Цвета/тема (тёмная, неон-фиолетовый бренд)
│   │   ├── state/selected_server.dart
│   │   ├── services/
│   │   │   ├── api_client.dart   HTTP-клиент к /api/v1 (см. раздел 6)
│   │   │   ├── tunnel_service.dart  Обёртка над sing-box (см. раздел 7)
│   │   │   └── local_prefs.dart  Обёртка над SharedPreferences (тумблеры настроек)
│   │   ├── screens/               14 экранов (см. раздел 5.1)
│   │   └── widgets/neon.dart      Общие UI-виджеты бренда
│   ├── android/ ios/ macos/ windows/ linux/ web/   Платформенные проекты Flutter
│   ├── assets/icon/               Исходники фирменной иконки (генерируется в mipmap/AppIcon и т.д.)
│   ├── pubspec.yaml                Зависимости (см. раздел 4)
│   ├── NATIVE_SETUP.md             Платформенная настройка VPN-ядра
│   └── .gitignore                  build/, .dart_tool/ и т.д. (добавлен — раньше отсутствовал)
├── backend-patch/                 2 файла на замену в shopbot + вспомогательные скрипты
│   ├── api.py, database.py        Патч с исправлениями безопасности (см. раздел 10)
│   ├── ENV_ADDITIONS.env          Переменные, которые нужно добавить в .env бота
│   ├── set_payment_settings.py    Разовый скрипт записи платёжных настроек в БД бота
│   └── REPORT.md                  Отчёт аудита backend (что было не так, доказательства)
├── archive-old-fastapi-bridge/    УСТАРЕВШИЙ мост — только для истории, НЕ деплоить
├── .github/workflows/
│   ├── build-android.yml          Сборка debug/release APK (см. раздел 9)
│   └── scaffold-platforms.yml     Тестовый workflow-заглушка
├── SECURITY.md                    Более ранний аудит уязвимостей уровня приложения
├── CHANGELOG_v2.md … CHANGELOG_v5.md, FIXES_v12.md   История итераций
└── README.md                       Чек-лист разового деплоя (см. раздел 15 — местами устарел)
```

## Технологический стек

| Слой | Технология |
|---|---|
| Клиент | Flutter (Dart), Material 3, тёмная тема |
| VPN-ядро | sing-box через пакет `flutter_singbox_client: ^1.0.0` (GPL-3.0, только Android) |
| Протокол туннеля | VLESS + Reality (TLS-маскировка под легитимный TLS-сайт), опционально XTLS Vision flow |
| Хранилище токена | `flutter_secure_storage` (Android Keystore / iOS Keychain) |
| Локальные настройки | `shared_preferences` (тумблеры Kill Switch, DNS-защита, блок рекламы и т.д. — не токен) |
| HTTP | пакет `http` |
| Список приложений (split-tunnel) | `installed_apps` |
| Иконка приложения | `flutter_launcher_icons`, генерируется из `assets/icon/` |
| Backend | Flask (`shopbot`, вне этого репозитория) — `/api/v1/...` |
| БД backend | SQLite (`users.db`), доступ через `database.py` |
| Платежи | YooKassa, CryptoBot |
| CI/CD | GitHub Actions, Android APK (debug + подписанный release) |

## Клиентское приложение (Flutter)

### 5.1 Экраны и навигация

`main.dart` → `AppEntryPoint` (стадии `loading → onboarding → auth → app`,
восстановление сессии через `ApiClient.restoreSession()`) → `RootShell` с
нижней навигацией из 5 вкладок:

| Экран | Файл | Назначение |
|---|---|---|
| Онбординг | `onboarding_screen.dart` | Показывается один раз (флаг в SharedPreferences) |
| Вход/регистрация | `auth_screen.dart` | Email + код подтверждения, восстановление пароля |
| Подключение | `connect_screen.dart` | Кнопка Подключить/Отключить, live RX/TX/таймер из `TunnelService` |
| Мои ключи | `keys_screen.dart` | Список ключей, докупка устройств, продление |
| Баланс | `plans_screen.dart` | Покупка тарифа (`GLOBAL`-бандл на все локации) |
| Пополнение баланса | `topup_screen.dart` | YooKassa/CryptoBot → `pay_url` в браузере |
| Серверы | `servers_screen.dart` | Список локаций из `GET /hosts` (без хардкода) |
| Меню/профиль | `menu_screen.dart` | Email + баланс, переходы в остальные разделы |
| Реферальная программа | `referral_screen.dart` | Данные из того же `GET /user/profile` |
| Безопасность | `security_screen.dart` | Kill Switch, DNS-защита |
| Настройки | `settings_screen.dart` | Доп. тумблеры (блок рекламы, обход DPI и т.д.) |
| Split-туннелирование | `split_tunnel_screen.dart` | Выбор приложений в обход VPN (реальный список устройства) |
| Поддержка | `support_screen.dart` | Контакты бренда |

### 5.2 Сервисы

- **`ApiClient`** (`services/api_client.dart`) — синглтон, обязательная
  инициализация `ApiClient.init(apiKey:, baseUrl:)` в `main()` до
  `runApp()`. Хранит JWT-токен сессии в `flutter_secure_storage`
  (**не** в SharedPreferences — токен не должен лежать в открытом файле).
  Все методы см. раздел 6.
- **`TunnelService`** (`services/tunnel_service.dart`) — синглтон-обёртка
  над `SingboxClient` (пакет `flutter_singbox_client`). Разбирает
  VLESS-ссылки/подписку, собирает JSON-конфиг sing-box, управляет
  подключением, кем-инициированным авто-переподключением (Kill Switch),
  режимом «только прокси» (без системного VPN-разрешения). См. раздел 7.
- **`LocalPrefs`** (`services/local_prefs.dart`) — обёртка над
  `SharedPreferences` для несекретных тумблеров (`killSwitch`,
  `dnsProtection`, `blockAds`, `dpiBypass`, `proxyOnlyMode`,
  `splitTunnelBypass` — карта `{имя_пакета: bool}`).

### 5.3 Модель данных ключа

Ключ, приходящий с backend (`GET /user/keys`), содержит как минимум
`expiry_date`, `connection_string`, `devices_limit` — **не**
`vless_uri`/`active_in_panel`/`subscription_url`/`devices_used`, как было
в более ранней версии клиента (несовпадение с реальным API, уже
исправлено). `connection_string` — это либо готовая `vless://`-ссылка,
либо URL подписки 3x-ui (base64-список ссылок) — `TunnelService`
поддерживает оба варианта по префиксу строки (см. раздел 7).

## Backend-контракт API

Базовый URL: `https://api.vpnonline.shop/api/v1` (передаётся через
`--dart-define=API_BASE_URL=...`, дефолт в коде совпадает).
Все запросы — заголовок `X-API-Key: <SHOPBOT_API_KEY>`; после логина —
дополнительно `Authorization: Bearer <JWT>`.

| Метод и путь | Назначение | Ключевые поля запроса/ответа |
|---|---|---|
| `POST /auth/register/send-code` | Код подтверждения на email | `{email}` |
| `POST /auth/register` | Регистрация = вход одним шагом | `{email, password, code, username?}` → `{token, user}` |
| `POST /auth/login` | Вход | `{email, password}` → `{token, user}` |
| `POST /auth/reset-password/send-code` | Код для сброса пароля | Ответ всегда `{ok: true}` — защита от email-enumeration |
| `POST /auth/reset-password/confirm` | Подтверждение сброса | `{email, code, new_password}` |
| `GET /user/profile` | Профиль **+ баланс + реферальная статистика** одним вызовом | → `{user: {...}}` |
| `POST /user/trial` | Активация бесплатного пробного периода | → `{key: {...}}` |
| `GET /user/keys` | Список ключей пользователя | → `{keys: [...]}` (поля — см. 5.3) |
| `POST /key/upgrade-devices` | Докупка слота устройства | `{key_id}` → `{new_limit}` |
| `POST /key/create` | Покупка ключа (списывает баланс) | `{plan_id}` → `{key: {...}}` |
| `POST /key/extend` | Продление ключа | `{key_id, plan_id}` → `{key: {...}}` |
| `GET /hosts` | Список локаций (из таблицы `xui_hosts`, без служебных полей) | → `{hosts: [...]}` |
| `GET /plans` | Тарифы по хостам + спец-ключ `GLOBAL` | → `{plans: {...}}` |
| `POST /billing/topup` | Пополнение баланса | `{amount, method: 'yookassa'|'cryptobot'}` → `{pay_url}` |

Ошибки — `ApiException(statusCode, message)`, текст берётся из
`{"error": "..."}` тела ответа, если оно JSON.

## VPN-туннель: sing-box

`TunnelService._buildSingBoxConfig()` собирает JSON-конфиг под текущее
установленное ядро **sing-box 1.13.x** (подтверждено фактическим текстом
ошибки ядра при сборке — см. [Troubleshooting](#troubleshooting)).
Актуальная (после правок) структура:

- **Outbound `proxy`** — `type: vless`, TLS + `utls` (fingerprint chrome
  по умолчанию), при `security=reality` — блок `reality` с `public_key`/
  `short_id`; при включённом обходе DPI — `tls.fragment: true`.
- **Outbound `direct`** — обычный прямой выход, нужен как минимум для
  `route.final` и (если DNS-защита выключена) для DNS-запросов мимо
  туннеля.
- **DNS** — `dns.servers` с одним DoH-сервером `1.1.1.1`; при включённом
  тумблере «DNS-защита» у сервера стоит `detour: proxy` (резолв через
  туннель, приватнее); при выключенном — `detour` не указывается вовсе
  (резолв напрямую, работает сразу — это тот самый параметр, из-за
  которого раньше падало ядро, см. Troubleshooting).
- **Route rules** — `{'action': 'sniff'}` → `{'protocol': 'dns',
  'action': 'hijack-dns'}` → (если включён блок рекламы)
  `{'domain_suffix': [...15 доменов рекламных/аналитических сетей...],
  'action': 'reject'}`. `route.final = 'proxy'`.
- **Inbound** — жёсткая развилка: `proxyOnly=true` → один `mixed`-инбаунд
  на `127.0.0.1:2080` (SOCKS5+HTTP автоопределением, VPN-разрешение не
  запрашивается); иначе — `tun`-инбаунд (`172.19.0.1/30`, `auto_route`,
  `strict_route`, опционально `exclude_package` со списком приложений
  из Split-туннелирования).

Ни `outbounds`, ни `inbounds` **не используют** ни одно
deprecated/removed поле sing-box ≥ 1.13.0 (подробности миграции — в
Troubleshooting). Это единственное место в проекте, где формат
конфигурации жёстко привязан к конкретной мажорной версии ядра —
при обновлении `flutter_singbox_client` на версию с более новым
sing-box стоит свериться с
[sing-box.sagernet.org/migration](https://sing-box.sagernet.org/migration/)
на предмет новых deprecation-циклов.

Логика `connect()`: подгружает все профили из подписки (или один — если
`connection_string` уже `vless://...`), пробует каждый по очереди
(`checkConfig` → `connect` → ждёт `connected` до 12 секунд), при неудаче
переходит к следующему; если ни один не подключился — бросает
`TunnelException` с числом опробованных серверов и последней причиной
(это и есть текст «Не удалось запустить туннель ни на одном сервере
ключа (N шт.): …», который виден на скриншотах ошибок).

Kill Switch: при обрыве соединения не по инициативе пользователя и
включённом тумблере — до 3 попыток авто-переподключения с интервалом
3 секунды, пока `killSwitchBlocking` не сброшен.

## Секреты и конфигурация

| Переменная | Где используется | Как передаётся | Критичность |
|---|---|---|---|
| `SHOPBOT_API_KEY` | Flutter-клиент **и** backend (`.env` бота) | `--dart-define` при сборке (GitHub Secret → CI); **не** хардкожен в исходниках (см. Troubleshooting/расхождения) | Низкая как «секрет» — физически виден в собранном APK после декомпиляции; отсекает случайных ботов, не целевую атаку. Настоящая защита пользователя — JWT-токен сессии |
| `API_BASE_URL` | Flutter-клиент | `--dart-define`, дефолт в коде — `https://api.vpnonline.shop/api/v1` | Не секрет |
| `ANDROID_KEYSTORE_BASE64` (base64), `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD` | Только CI (подпись релизного APK) | GitHub Secrets → `.github/workflows/build-android.yml` | Высокая — компрометация позволяет подписывать поддельные обновления от имени приложения |
| `YOOKASSA_SHOP_ID`, `YOOKASSA_SECRET_KEY`, `CRYPTOBOT_TOKEN` | Только backend (shopbot), читаются из таблицы `bot_settings` через `database.py` | `backend-patch/set_payment_settings.py` (разово, локально) или админ-панель бота в Telegram | **Высокая** — платёжные секреты. Flutter-клиенту и CI этого репозитория не нужны вообще |
| `GMAIL_USER`, `GMAIL_APP_PASSWORD` | Только backend | `.env` бота (см. `ENV_ADDITIONS.env`) | Высокая — доступ к почтовому ящику рассылки кодов |
| `TELEGRAM_BOT_TOKEN` | Backend/сам Telegram-бот (вне этого репозитория) | Секрет виден в Settings репозитория на скриншоте, но **не используется** ни `build-android.yml`, ни каким-либо файлом в `app/` | Высокая, но вне зоны ответственности этого CI |

**Важно:** `build-android.yml` собирает только Flutter-клиент и
использует из всего списка секретов репозитория ровно шесть:
`SHOPBOT_API_KEY`, `API_BASE_URL`, `ANDROID_KEYSTORE_BASE64`,
`ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`.
Платёжные, почтовые и Telegram-секреты в клиентскую сборку **осознанно
не проброшены** — они принадлежат серверной части и не имеют отношения
к тому, что компилируется в APK.

## CI/CD

`.github/workflows/build-android.yml` (`workflow_dispatch` + `push` на
`main`/`fix/secure-configs-and-ci` + `pull_request` на `main`):

1. Checkout → освобождение места на раннере (удаление .NET/Android
   NDK/CodeQL/ghc и т.п. — Android-сборка Flutter иначе не помещается на
   стандартном раннере).
2. JDK 17 (temurin), Flutter stable.
3. `flutter pub get`.
4. `dart run flutter_launcher_icons` — генерация фирменной иконки из
   `assets/icon/` (раньше не запускался — CI собирал APK со стандартной
   иконкой Flutter).
5. `flutter analyze` / `flutter test --coverage` (оба `|| true` — не
   блокируют сборку).
6. Debug APK — с `--dart-define` для `API_BASE_URL`/`SHOPBOT_API_KEY`,
   всегда собирается и выкладывается как артефакт.
7. Подготовка подписи: если задан секрет `ANDROID_KEYSTORE_BASE64` (base64) —
   декодируется в `android/keystore/keystore.jks`, пишется
   `android/key.properties` из остальных трёх секретов подписи.
8. Release APK — подписанный, если `keystore.jks` создан на шаге 7,
   иначе unsigned (годится для ручного теста, не для публикации).
9. Оба APK выкладываются как GitHub Actions Artifacts
   (`app-debug-apk`, `app-release-apk`).

`scaffold-platforms.yml` — тестовая заглушка (`echo`/`date`), не влияет
на сборку.

## Безопасность — сводка

Полные отчёты: `SECURITY.md` (аудит уровня приложения, более ранняя
итерация), `backend-patch/REPORT.md` (аудит реального кода бота).
Коротко, что уже исправлено на backend-стороне патчем:

- Подделываемый токен `dev-token-{email}` → подписанный JWT (HMAC-SHA256).
- Вебхуки платежей проверяются по API провайдера / HMAC-подписи, а не
  доверяют телу входящего запроса напрямую.
- Идемпотентность вебхуков (повторная доставка не выдаёт ключ дважды).
- Цена заказа всегда считается на сервере из `plan_id`, не из тела
  запроса клиента.
- Лимит попыток ввода кода подтверждения (5) + минимум 60с между
  повторными отправками.
- Убрано логирование полного тела платёжных вебхуков.
- Все запросы к БД — параметризованные (SQLAlchemy `text()` с
  bind-параметрами), без склейки строк.
- Убран захардкоженный fallback-пароль Gmail и захардкоженный
  дефолтный `SHOPBOT_API_KEY` (`default_secure_shopbot_api_key`) — оба
  считать скомпрометированными, если использовались.
- Устранена гонка (TOCTOU) при списании баланса в `/key/create`,
  `/key/extend`, докупке устройств — переведено на атомарную
  `deduct_from_balance()`.
- `/auth/reset-password/send-code` больше не раскрывает существование
  email в базе (единый ответ `{ok: true}`).

Не проверено / не в зоне ответственности кода:
реальная схема таблиц твоего форка бота (см. `REPORT.md`), сетевой
rate-limiting (уровень nginx/Cloudflare, не приложения), полноценный
пентест боевого окружения.

## Установка и разработка

```bash
cd app
flutter pub get
dart run flutter_launcher_icons     # один раз, генерирует фирменную иконку

# Локальный дебаг-запуск на реальном Android-устройстве
# (эмулятор для VPN-функциональности не подходит, см. NATIVE_SETUP.md):
flutter run -d android \
  --dart-define=SHOPBOT_API_KEY=<ключ из .env бота> \
  --dart-define=API_BASE_URL=https://api.vpnonline.shop/api/v1
```

Без `SHOPBOT_API_KEY` приложение соберётся и запустится, но любой
запрос к API упадёт с ошибкой авторизации сразу (это осознанное
поведение — см. комментарий в `main.dart`, дефолтного значения ключа в
коде больше нет).

## Деплой релиза — чек-лист

1. **Backend** (на сервере, где крутится shopbot):
   `cp backend-patch/api.py database.py <путь_к_shopbot>/src/shop_bot/webhook_server/` —
   сначала `git diff`, если после прошлых итераций эти файлы правились
   вручную.
2. Заполнить `.env` бота по `backend-patch/ENV_ADDITIONS.env` (значения
   вписывать **локально на сервере**, не коммитить заполненную версию).
3. Заполнить и один раз выполнить `backend-patch/set_payment_settings.py
   <путь_к_users.db>` — **после** перевыпуска YooKassa/CryptoBot-ключей
   (см. предупреждение в разделе «Секреты»).
4. Перезапустить бота.
5. В Settings → Secrets and variables → Actions репозитория убедиться,
   что заданы: `SHOPBOT_API_KEY`, `API_BASE_URL`, `ANDROID_KEYSTORE_BASE64`,
   `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`.
6. Запустить workflow «Build Android APK» (push в `main` или вручную
   через `workflow_dispatch`) → скачать `app-release-apk` из Artifacts.
7. Первый реальный тест на физическом устройстве: регистрация → код на
   почту, логин, покупка тестового тарифа, подключение туннеля, смена
   внешнего IP, split-tunnel список приложений, отключение гасит
   VPN-иконку в шторке.

## Известные ограничения

- **Платформы:** `flutter_singbox_client` на сегодня поддерживает только
  **Android**. iOS/macOS — «в разработке» у автора пакета, Windows/Linux
  — «в планах». На остальных платформах приложение соберётся и покажет
  весь UI (авторизация, покупка, список ключей/серверов), но кнопка
  «Подключить» не поднимет реальный туннель.
- **Лицензия:** `flutter_singbox_client` — GPL-3.0 (в отличие от
  предыдущего `flutter_vless`, который был MIT). При распространении
  собранного приложения (не только личном использовании) это накладывает
  требования GPL — стоит свериться с юристом по условиям
  распространения.
- **`connection_string`:** формируется функцией
  `xui_api.get_key_details_from_host_sync()` на бэкенде, исходный код
  которой не входил в проверенные файлы. `_loadProfiles()` в
  `tunnel_service.dart` поддерживает оба варианта (готовая ссылка / URL
  подписки), но если после реального теста подключение не работает —
  это первое место для проверки.
- **Точные имена `ServiceState`/`TrafficStats`** пакета
  `flutter_singbox_client` не были полностью опубликованы в его README
  на момент написания кода — сопоставление в `_mapServiceState()`
  сделано через `toString()` по наиболее вероятным именам, устойчиво к
  небольшим отличиям, но стоит свериться при обновлении версии пакета.

## Troubleshooting

### `CONNECT_FAILED` / `detour to an empty direct outbound makes no sense`

Причина: `dns.servers[].detour` указывал на `direct`-outbound без
дополнительных опций — sing-box (≥ ~1.12.x) считает такой `detour`
бессмысленным и падает при старте. **Исправлено**: `detour` теперь
добавляется в объект DNS-сервера только когда реально нужно увести
DNS-запросы через прокси (тумблер «DNS-защита» включён); при выключенном
тумблере поле просто не пишется, и sing-box резолвит напрямую сам.

### `INVALID_CONFIG` / `legacy inbound fields are deprecated in sing-box 1.11.0 and removed in sing-box 1.13.0`

Причина: установленное ядро — **sing-box 1.13.x**, а конфиг всё ещё
использовал синтаксис, удалённый именно в этой версии:
- `'sniff': true` прямо в объекте `inbound` («legacy inbound fields»);
- outbound'ы `{'type': 'dns', ...}` / `{'type': 'block', ...}` +
  маршруты `{'protocol': 'dns'/'domain_suffix', 'outbound': '...'}`
  («legacy special outbounds»).

**Исправлено** — оба заменены на актуальный формат sing-box
(`route.rules` с полем `action`: `sniff`, `hijack-dns`, `reject`), без
единого `dns`/`block`-outbound'а в конфиге. Подробности и ссылки на
официальную миграцию — в комментариях прямо над
`_buildSingBoxConfig()` в `tunnel_service.dart`.

### Релизный APK собирается неподписанным

Если секреты `ANDROID_KEYSTORE_BASE64`/`ANDROID_KEYSTORE_PASSWORD`/
`ANDROID_KEY_ALIAS`/`ANDROID_KEY_PASSWORD` заданы в Settings → Secrets
репозитория (имя первого — именно `ANDROID_KEYSTORE_BASE64`, проверено
владельцем репозитория), шаг «Prepare signed release» их подхватывает
автоматически. Если релиз всё равно unsigned — проверить, что base64 в
`ANDROID_KEYSTORE_BASE64` декодируется в валидный `.jks`
(`echo "$VALUE" | base64 -d > test.jks && keytool -list -keystore test.jks`)
и что значение секрета не содержит случайных переносов строк/пробелов.

### `Unauthorized: Invalid or missing API key` на экране входа

Значит `SHOPBOT_API_KEY` не был передан при сборке (`--dart-define` не
задан или GitHub Secret пуст) **или** он не совпадает со значением в
`.env` сервера — сверить оба места.

### На экране Split-туннелирование у всех приложений эмодзи 📱 вместо иконок

Причина: `InstalledApps.getInstalledApps()` (пакет `installed_apps`)
параметр `withIcon` по умолчанию — `false`; без него `app.icon` всегда
`null`, независимо от устройства. **Исправлено** — вызов теперь передаёт
`withIcon: true` (`screens/split_tunnel_screen.dart`), сам UI-код
рендеринга иконки (`Image.memory`/эмодзи-заглушка как fallback на пустой
`icon`) не менялся, он был написан верно с самого начала.

## Расхождения со старыми README/CHANGELOG

Для честности: `README.md` (раздел «Что нужно сделать тебе», п.4)
утверждает, что GitHub Secret `SHOPBOT_API_KEY` «больше не обязателен»,
потому что ключ был прописан значением по умолчанию прямо в
`main.dart`. Это верно для более ранней версии кода, но **уже
неактуально**: в текущем `main.dart` дефолтное значение сознательно
убрано (см. комментарий в самом файле — «критично перед публикацией
репозитория», иначе ключ был бы виден любому, кто откроет `main.dart`
на GitHub). Сейчас `SHOPBOT_API_KEY` **обязателен** через
`--dart-define`/GitHub Secret — этот документ и раздел
[«Секреты и конфигурация»](#секреты-и-конфигурация) отражают актуальное
состояние; README в этом месте не обновлялся при том исправлении.
