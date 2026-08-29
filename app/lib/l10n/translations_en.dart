/// [НОВОЕ] Модуль переводчика — карта переводов "русский текст из кода" ->
/// "английский перевод". Ключи — ТОЧНЫЕ русские строки, как они написаны в
/// виджетах (см. lib/services/locale_service.dart::translate). Если строка
/// вызывается через `tr('...')`, но её здесь нет — пользователь просто
/// увидит русский оригинал (безопасный fallback, не пустая строка и не
/// ключ-заглушка).
///
/// Покрытие на данный момент (см. REPORT_TRANSLATOR.md за полным списком):
/// main.dart, settings_screen.dart — переведены полностью. Остальные экраны
/// — postponed, вернуться к ним по запросу.
const Map<String, String> translationsEn = {
  // ── main.dart — нижняя навигация + сессия ──────────────────────────────
  'Главная': 'Home',
  'Ключи': 'Keys',
  'Баланс': 'Balance',
  'Серверы': 'Servers',
  'Меню': 'Menu',
  'Сессия устарела — войдите заново': 'Your session has expired — please sign in again',

  // ── settings_screen.dart ───────────────────────────────────────────────
  'Настройки': 'Settings',
  'Автоподключение при запуске': 'Auto-connect on launch',
  'Поднимает VPN сразу при открытии приложения, если уже есть сохранённый ключ':
      'Starts the VPN as soon as the app opens, if a key is already saved',
  'Умное подключение на публичном Wi-Fi': 'Smart connect on public Wi-Fi',
  'Включает VPN при переходе на любую Wi-Fi-сеть — ОС не даёт отличить публичную от домашней без спецправ':
      'Turns on the VPN when switching to any Wi-Fi network — the OS can\'t tell public from home Wi-Fi without special permissions',
  'Kill Switch': 'Kill Switch',
  'Автоматически переподключает туннель при обрыве связи. Тот же переключатель, что и в разделе «Безопасность»':
      'Automatically reconnects the tunnel if the connection drops. Same toggle as in the "Security" section',
  'Обход DPI (фрагментация TLS)': 'DPI bypass (TLS fragmentation)',
  'Дробит первый TLS-пакет на части — помогает, если провайдер режет Reality-соединения по сигнатуре. Применится при следующем подключении':
      'Splits the first TLS packet into fragments — helps if your provider blocks Reality connections by signature. Applies on the next connection',
  'Режим прокси (без VPN-разрешения)': 'Proxy mode (no VPN permission)',
  'Локальный SOCKS5/HTTP-порт на телефоне вместо системного VPN — Kill Switch и split-tunnel в этом режиме не работают':
      'A local SOCKS5/HTTP port on the phone instead of the system VPN — Kill Switch and split tunneling don\'t work in this mode',
  'Активен:': 'Active:',
  'укажи этот адрес в настройках прокси нужного приложения':
      'set this address in the proxy settings of the app you want to use',
  'Порт появится здесь после подключения (127.0.0.1:2080, SOCKS5 и HTTP)':
      'The port will appear here after connecting (127.0.0.1:2080, SOCKS5 and HTTP)',
  'Язык': 'Language',
  'Меняет язык интерфейса приложения': 'Changes the app interface language',
  'DNS-сервер': 'DNS server',
  'DNS-over-HTTPS резолвер для доменов внутри туннеля. Применится при следующем подключении':
      'DNS-over-HTTPS resolver for domains inside the tunnel. Applies on the next connection',
  'Например: 9.9.9.11': 'e.g. 9.9.9.11',
  'Разрешить IPv6 в туннеле': 'Allow IPv6 in the tunnel',
  'Пропускает IPv6-трафик через VPN в дополнение к IPv4. Применится при следующем подключении':
      'Passes IPv6 traffic through the VPN in addition to IPv4. Applies on the next connection',
  'Очистить кэш': 'Clear cache',
  'Удаляет избранные серверы и локальный выбор split-туннелирования. Вход в аккаунт сохранится':
      'Deletes favorite servers and local split-tunneling choices. You\'ll stay signed in',
  'Выйти из аккаунта': 'Sign out',
  'Выйти из аккаунта?': 'Sign out?',
  'Тебе нужно будет снова войти по email и паролю.': 'You\'ll need to sign in again with your email and password.',
  'Отмена': 'Cancel',
  'Выйти': 'Sign out',
  'Очистить кэш?': 'Clear cache?',
  'Локальные данные приложения (кэш серверов, избранное) будут удалены. Вход в аккаунт при этом сохранится.':
      'Local app data (server cache, favorites) will be deleted. You\'ll stay signed in.',
  'Очистить': 'Clear',
  'Кэш очищен': 'Cache cleared',
  'Изменение применится при следующем подключении — переподключись, чтобы включить сейчас':
      'This change applies on the next connection — reconnect to enable it now',
  'Применится при следующем подключении — переподключись, чтобы включить сейчас':
      'Applies on the next connection — reconnect to enable it now',
  'Применится при следующем подключении — переподключись, чтобы сменить режим сейчас':
      'Applies on the next connection — reconnect to switch modes now',
  'Применится при следующем подключении — переподключись, чтобы сменить DNS сейчас':
      'Applies on the next connection — reconnect to switch DNS now',

  // ── menu_screen.dart ────────────────────────────────────────────────────
  'Мой аккаунт': 'My account',
  'Баланс:': 'Balance:',
  'активных ключей': 'active keys',
  'Загрузка баланса…': 'Loading balance…',
  'Мои ключи': 'My keys',
  'Пополнить баланс': 'Top up balance',
  'Купить ключ / тарифы': 'Buy a key / plans',
  'Split-туннелирование': 'Split tunneling',
  'Бесплатный период': 'Free trial',
  'Реферальная программа': 'Referral program',
  'Безопасность (Kill Switch, DNS)': 'Security (Kill Switch, DNS)',
  'Поддержка и контакты': 'Support & contacts',
  'Активировать бесплатный пробный период? Ключ появится сразу во всех доступных локациях в разделе «Мои ключи».':
      'Activate the free trial? A key will appear right away in every available location, under "My keys".',
  'Активировать': 'Activate',
  'Триал активирован — смотри «Мои ключи»': 'Trial activated — check "My keys"',

  // ── onboarding_screen.dart ──────────────────────────────────────────────
  'Пропустить': 'Skip',
  'Далее': 'Next',
  'Начать': 'Get started',
  'Приватность без компромиссов': 'Privacy without compromise',
  'VLESS · Reality — протокол, который маскирует VPN-трафик под обычный HTTPS. Никаких логов активности.':
      'VLESS · Reality — a protocol that disguises VPN traffic as regular HTTPS. No activity logs.',
  'Без просадки скорости': 'No speed loss',
  'Автобалансировка между локациями подбирает самый быстрый сервер для тебя прямо сейчас.':
      'Auto-balancing across locations picks the fastest server for you right now.',
  'Приглашай — экономь': 'Invite — and save',
  'Реферальная программа начисляет бонус на баланс за каждого друга, который оформит платный тариф.':
      'The referral program credits your balance for every friend who buys a paid plan.',

  // ── auth_screen.dart ────────────────────────────────────────────────────
  'Не удалось выполнить запрос:': 'Request failed:',
  'Код отправлен на почту (если такой email ещё не зарегистрирован)':
      'Code sent to your email (if that email isn\'t registered yet)',
  'Если аккаунт с таким email существует — код отправлен на почту':
      'If an account with this email exists, a code has been sent to it',
  'Пароль обновлён — теперь можно войти': 'Password updated — you can now sign in',
  'Вход в кабинет': 'Sign in',
  'Создать аккаунт': 'Create account',
  'Подтверждение почты': 'Confirm your email',
  'Сброс пароля': 'Reset password',
  'Новый пароль': 'New password',
  'Тот же аккаунт, что на сайте и в Telegram-боте': 'The same account as on the website and Telegram bot',
  'Один аккаунт — сайт, бот и приложение': 'One account — website, bot, and app',
  'Введи код из письма (проверь папку «Спам»)': 'Enter the code from the email (check your Spam folder)',
  'Введи email — пришлём код для восстановления': 'Enter your email — we\'ll send a recovery code',
  'Код из письма и новый пароль (минимум 6 символов)': 'The code from the email and a new password (6 characters minimum)',
  'Email адрес': 'Email address',
  'Пароль': 'Password',
  'Имя пользователя (необязательно)': 'Username (optional)',
  'Код из письма': 'Code from the email',
  'Новый пароль (минимум 6 символов)': 'New password (6 characters minimum)',
  'Войти в аккаунт': 'Sign in',
  'Зарегистрироваться': 'Sign up',
  'Подтвердить': 'Confirm',
  'Получить код': 'Get code',
  'Сбросить пароль': 'Reset password',
  'Нет аккаунта? Создать аккаунт': 'No account? Create one',
  'Забыли пароль?': 'Forgot password?',
  'Уже есть аккаунт? Войти в кабинет': 'Already have an account? Sign in',
  'Вернуться ко входу': 'Back to sign in',

  // ── connect_screen.dart ─────────────────────────────────────────────────
  'Подключение': 'Connect',
  'Используется ключ, добавленный вручную': 'Using a manually added key',
  'Туннель неожиданно оборвался — восстанавливаю соединение. Интернет сейчас идёт БЕЗ защиты VPN.':
      'The tunnel dropped unexpectedly — reconnecting. Internet traffic is currently NOT protected by the VPN.',
  'Повторить попытку': 'Try again',
  'Автовыбор': 'Auto-select',
  'Приём': 'Down',
  'Отдача': 'Up',
  'Устройств': 'Devices',
  'Оформить подписку': 'Get a subscription',
  'Сменить сервер': 'Change server',
  'Отключить': 'Disconnect',
  'Подключить': 'Connect',
  'Тест скорости': 'Speed test',
  'Тест скорости доступен после подключения к серверу': 'Speed test is available after connecting to a server',
  'НЕТ КЛЮЧА': 'NO KEY',
  'ПОДКЛЮЧЕНО': 'CONNECTED',
  'ОТКЛЮЧЕНО': 'DISCONNECTED',
  'VLESS · Reality': 'VLESS · Reality',
  'Ключ обновлён. Переподключись, чтобы применить его.': 'Key updated. Reconnect to apply it.',
  'Не удалось проверить статус ключа:': 'Failed to check key status:',
  'Срок действия предыдущего ключа истёк — переключились на следующий активный ключ':
      'The previous key has expired — switched to the next active key',
  'Ключ истёк, а переключиться на следующий не удалось:': 'The key expired and switching to the next one failed:',
  'Срок действия ключа истёк, других активных ключей нет — оформи новую подписку':
      'The key has expired and there are no other active keys — get a new subscription',
  'Для этого ключа пока нет ссылки на конфигурацию сервера — обратись в поддержку.':
      'There\'s no server configuration link for this key yet — please contact support.',
  'Не удалось подключиться:': 'Failed to connect:',
  'Настройки VPN': 'VPN settings',
  'проверка соединения…': 'checking connection…',
  'сервер не отвечает на проверку задержки': 'the server isn\'t responding to the latency check',
  'мс · отличный сигнал': 'ms · excellent signal',
  'мс · стабильно': 'ms · stable',
  'мс · медленно': 'ms · slow',

  // ── balance_screen.dart ─────────────────────────────────────────────────
  'БАЛАНС АККАУНТА': 'ACCOUNT BALANCE',
  'Активных ключей': 'Active keys',
  'Всего ключей': 'Total keys',
  'Не удалось загрузить баланс': 'Failed to load balance',
  'Купить / продлить ключ': 'Buy / renew key',
  'Повторить': 'Retry',

  // ── referral_screen.dart ────────────────────────────────────────────────
  'Приглашай друзей своей ссылкой — за их покупки на твой баланс начисляется бонус (процент настроен в боте, актуальную ставку уточняй в поддержке).':
      'Invite friends with your link — you get a balance bonus for their purchases (the rate is set in the bot; check support for the current rate).',
  'Не удалось загрузить реферальные данные:': 'Failed to load referral data:',
  'Твоя ссылка': 'Your link',
  'Скопировать': 'Copy',
  'Ссылка скопирована': 'Link copied',
  'Приглашено': 'Invited',
  'Заработано': 'Earned',

  // ── split_tunnel_screen.dart ────────────────────────────────────────────
  'Выбор приложений доступен только на Android — на этой платформе список системы недоступен.':
      'App selection is only available on Android — the system list isn\'t available on this platform.',
  'Не удалось получить список приложений:': 'Failed to get the list of apps:',
  'Обход выбранных': 'Bypass selected',
  'Только выбранные': 'Only selected',
  'Через VPN работают ТОЛЬКО отмеченные ниже приложения — остальные всегда напрямую.':
      'ONLY the apps checked below use the VPN — everything else always goes direct.',
  'Отмеченные ниже приложения работают в обход VPN — например банк или локальные сервисы. Список — реальные приложения с этого устройства.':
      'The apps checked below bypass the VPN — for example a bank app or local services. This list is the real apps on this device.',

  // ── support_screen.dart ─────────────────────────────────────────────────
  'Сайт': 'Website',
  'Бот Telegram': 'Telegram bot',
  'Бот MAX': 'MAX bot',
  'Бот тех. поддержки': 'Support bot',
  'Канал новостей': 'News channel',
  'О приложении': 'About the app',
  'Версия': 'Version',
  'Протокол': 'Protocol',
  'Политика логов': 'Log policy',
  'No-logs': 'No-logs',

  // ── topup_screen.dart ───────────────────────────────────────────────────
  'Введи сумму от 10 ₽': 'Enter an amount of at least 10 ₽',
  'Открыта страница оплаты — после оплаты баланс обновится автоматически':
      'Payment page opened — your balance will update automatically after payment',
  'Не удалось открыть страницу оплаты': 'Failed to open the payment page',
  'Не удалось создать платёж:': 'Failed to create the payment:',
  'Способ оплаты': 'Payment method',
  'ЮKassa · СБП / карта': 'YooKassa · SBP / card',
  'Пополнение баланса внутри iOS-приложения недоступно. '
      'Оформи и оплати подписку на сайте или в Telegram-боте — '
      'ключ появится в приложении автоматически.':
      'Topping up your balance inside the iOS app isn\'t available. '
      'Subscribe and pay on the website or via the Telegram bot — '
      'the key will appear in the app automatically.',
  'Где купить ключ': 'Where to buy a key',
  'Сайт vpnonline.su': 'vpnonline.su website',
  'Telegram-бот': 'Telegram bot',
  'Пополнить': 'Top up',

  // ── keys_screen.dart ────────────────────────────────────────────────────
  'Похоже на неверную ссылку — жду vless://... или http(s)://ссылку на подписку':
      'That looks like an invalid link — expected a vless://... link or an http(s):// subscription link',
  'Ручной ключ удалён': 'Manual key removed',
  'Ключ сохранён — теперь подключение пойдёт по нему': 'Key saved — the connection will now use it',
  'Сначала вставь vless://-ссылку или ссылку на подписку': 'First paste a vless:// link or a subscription link',
  'Найдено серверов:': 'Servers found:',
  'Ок': 'OK',
  'Ключ не распознан': 'Key not recognized',
  'Ручной ключ удалён — снова используются ключи из личного кабинета':
      'Manual key removed — keys from your account are used again',
  'Не удалось загрузить ключи:': 'Failed to load keys:',
  'Лимит устройств увеличен до': 'Device limit increased to',
  'У тебя пока нет ключей': 'You don\'t have any keys yet',
  'Купить новый ключ': 'Buy a new key',
  'Ключ': 'Key',
  'активен': 'active',
  'истёк': 'expired',
  'Копировать': 'Copy',
  'Ссылка временно недоступна — панель могла быть недоступна при запросе':
      'The link is temporarily unavailable — the panel may have been unreachable when requested',
  'Лимит устройств': 'Device limit',
  '+ докупить (50 ₽)': '+ add one (50 ₽)',
  'Срок действия': 'Expires',
  'Осталось': 'Remaining:',
  'дн.': 'd.',
  'Продлить ключ': 'Renew key',
  'Свой ключ (вручную)': 'Custom key (manual)',
  'Вставь vless://-ссылку или ссылку на подписку — приложение подключится именно по ней, в приоритете перед ключами из личного кабинета. Оставь поле пустым и сохрани, чтобы вернуться к ключам из личного кабинета.':
      'Paste a vless:// link or a subscription link — the app will connect through it, taking priority over keys from your account. Leave the field empty and save to go back to using account keys.',
  'vless://... или https://.../sub/...': 'vless://... or https://.../sub/...',
  'Сохранить': 'Save',
  'Удалить': 'Delete',
  'Проверить ключ': 'Check key',

  // ── plans_screen.dart ───────────────────────────────────────────────────
  'Не удалось загрузить тарифы:': 'Failed to load plans:',
  'день': 'day',
  'дня': 'days',
  'дней': 'days',
  'Ключ продлён': 'Key renewed',
  'Ключ выдан — смотри вкладку «Ключи»': 'Key issued — check the "Keys" tab',
  'Не удалось оформить:': 'Failed to complete the purchase:',
  'Продление ключа': 'Renew key',
  'Оформление подписки': 'Get a subscription',
  'Единый VPN-ключ даёт доступ ко всем локациям сразу — выбирать сервер не нужно. Оплата — с баланса аккаунта.':
      'A single VPN key gives access to all locations at once — no need to pick a server. Paid from your account balance.',
  'Тарифы пока не настроены в панели бота (нет тарифов для host "GLOBAL").':
      'Plans haven\'t been set up in the bot panel yet (no plans for host "GLOBAL").',
  'Продлить —': 'Renew —',
  'Получить ключ —': 'Get key —',

  // ── security_screen.dart ────────────────────────────────────────────────
  '1 день': '1 day',
  '7 дней': '7 days',
  '30 дней': '30 days',
  'Удалить все логи?': 'Delete all logs?',
  'Локальный журнал событий приложения (подключения, ошибки) будет удалён полностью. Действие необратимо.':
      'The app\'s local event log (connections, errors) will be deleted completely. This can\'t be undone.',
  'Логи удалены': 'Logs deleted',
  'Kill Switch включён автоматически — строгий режим работает поверх него':
      'Kill Switch was turned on automatically — strict mode works on top of it',
  'Безопасность': 'Security',
  'Kill Switch активен: сервер недоступен, интернет физически заблокирован до восстановления туннеля':
      'Kill Switch is active: the server is unreachable, internet is physically blocked until the tunnel recovers',
  'Автоматически переподключает туннель при обрыве': 'Automatically reconnects the tunnel if it drops',
  'Строгий режим (блокировать трафик)': 'Strict mode (block traffic)',
  'Если переподключиться не удалось — интернет физически блокируется':
      'If reconnecting fails, internet is physically blocked',
  'Выключено: при неудаче просто останется обычный интернет': 'Off: on failure, regular internet just stays on',
  'Дополнительно: включить блокировку без VPN на уровне системы Android':
      'Advanced: turn on blocking without VPN at the Android system level',
  'Защита от DNS-протечек': 'DNS leak protection',
  'Весь DNS-трафик идёт через туннель': 'All DNS traffic goes through the tunnel',
  'Fake IP (DNS)': 'Fake IP (DNS)',
  'Резолв доменов через служебные адреса — быстрее и без утечки таймингов':
      'Resolves domains via internal addresses — faster and without timing leaks',
  'Блокировка рекламы и трекеров': 'Ad & tracker blocking',
  'На уровне DNS-фильтрации': 'At the DNS-filtering level',
  'Обход локальной сети': 'Bypass local network',
  'Устройства в LAN (роутер, принтер, NAS) доступны напрямую': 'LAN devices (router, printer, NAS) are reachable directly',
  'LAN тоже идёт через VPN — доступ к сети сервера': 'LAN also goes through the VPN — access to the server\'s network',
  'Mux (мультиплексирование)': 'Mux (multiplexing)',
  'Несколько потоков через одно соединение — быстрее открытие сайтов': 'Multiple streams over one connection — sites load faster',
  'Протокол:': 'Protocol:',
  'Агрессивное переподключение': 'Aggressive reconnect',
  'До 8 попыток восстановить туннель при обрыве': 'Up to 8 attempts to restore the tunnel after a drop',
  'До 3 попыток восстановить туннель при обрыве': 'Up to 3 attempts to restore the tunnel after a drop',
  'Хранение логов': 'Log storage',
  'Срок хранения логов': 'Log retention period',
  'Записи старше срока': 'Entries older than',
  'удаляются автоматически': 'are deleted automatically',
  'Сохранено записей': 'Entries stored',
  'События подключения и ошибки за выбранный период': 'Connection events and errors for the selected period',
  'Просмотреть логи': 'View logs',
  'Удалить все логи': 'Delete all logs',

  // ── logs_viewer_screen.dart ─────────────────────────────────────────────
  'Логи приложения': 'App logs',
  'Технический журнал событий на устройстве: подключения, ошибки. Это не логи трафика — политика провайдера No-logs не затрагивается.':
      'A technical event log on the device: connections, errors. This is not traffic logging — the No-logs policy is unaffected.',
  'Логов пока нет': 'No logs yet',

  // ── servers_screen.dart ─────────────────────────────────────────────────
  'Выбор сервера': 'Choose a server',
  'Список подтягивается напрямую из панелей 3x-ui через backend — новая локация появляется здесь автоматически.':
      'The list is pulled directly from the 3x-ui panels via the backend — new locations appear here automatically.',
  'Реальная проверка серверов': 'Real server check',
  'сначала отключитесь от VPN': 'disconnect from the VPN first',
  'проверяю': 'checking',
  'реально поднимает VLESS к каждому серверу — точнее пинга': 'actually brings up VLESS to each server — more accurate than a ping',
  'Проверить': 'Check',
  'В панелях 3x-ui пока нет активных локаций.': 'There are no active locations in the 3x-ui panels yet.',
  'Без названия': 'Unnamed',
  'Не удалось получить список серверов:': 'Failed to get the server list:',
  'измеряю через VLESS...': 'measuring via VLESS...',
  'мс · отличный сигнал (через VLESS)': 'ms · excellent signal (via VLESS)',
  'мс · отлично (через VLESS)': 'ms · excellent (via VLESS)',
  'мс · через VLESS': 'ms · via VLESS',
  'мс · медленно (через VLESS)': 'ms · slow (via VLESS)',
  'измеряю...': 'measuring...',
  'нет данных для пинга': 'no ping data',
  'недоступен': 'unreachable',
  'мс · сеть (VLESS не проверен)': 'ms · network only (VLESS unverified)',
  'мс · отлично': 'ms · excellent',
  'мс': 'ms',
  'проверяю по-настоящему...': 'really checking...',
  'работает ·': 'working ·',
  'мс (проверено)': 'ms (verified)',
  'не работает': 'not working',
  'нет ответа': 'no response',
  'выбран': 'selected',
  'Авто-балансировка': 'Auto load balancing',
  'реально переключились на': 'actually switched to',
  'следим за пингом каждые 25 с и переключаем туннель сами': 'we watch ping every 25s and switch the tunnel automatically',
  'выбор лучшего сервера': 'picks the best server',
  'Не удалось переключиться на': 'Failed to switch to',
  'Нет активного ключа с подпиской — нечего проверять.': 'No active key with a subscription — nothing to check.',
  'Сначала отключитесь от VPN — реальная проверка на время поднимает и гасит тестовое соединение тем же движком.':
      'Disconnect from the VPN first — the real check temporarily brings up and tears down a test connection using the same engine.',
};