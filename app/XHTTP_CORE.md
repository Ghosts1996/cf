# XHTTP: что нужно, чтобы такие ключи заработали

## Коротко

Приложение уже умеет собирать конфиг с транспортом **XHTTP** (он же splithttp)
и само проверяет, понимает ли его установленное ядро. Не хватает только
ядра: штатный `libbox.aar` собран из апстримного sing-box, а XHTTP в апстриме
нет — это транспорт Xray, и в sing-box его добавили только в форке, на
котором работает Hiddify.

Пока ядро прежнее, поведение ровно как раньше: XHTTP-локации отсеиваются,
остальные работают. Подменили ядро на сборку с XHTTP — приложение начинает
их использовать, ничего не пересобирая в Dart-коде.

## Что проверено

Оба ядра собирались из исходников и проверялись на конфиге, который
генерирует само приложение (`TunnelService.buildConfigFromUri`):

| Конфиг | sing-box 1.12.9 (апстрим, как сейчас) | hiddify-sing-box (форк) |
|---|---|---|
| обычный VLESS+Reality | принят | принят |
| VLESS + XHTTP | `unknown transport type: xhttp` | принят |

Отсюда два следствия, которые учтены в коде:

- `mode` для XHTTP обязателен. Без него ядро с поддержкой транспорта
  отвечает `xhttp: mode is not set`, поэтому при отсутствии параметра в
  ссылке подставляется `auto` — так же делает Hiddify.
- Определять поддержку по версии ядра бессмысленно (форк и апстрим имеют
  одинаковые номера версий), поэтому приложение спрашивает у ядра напрямую:
  отдаёт на `checkConfig` минимальный конфиг с XHTTP и смотрит на ответ.
  Результат кэшируется на время работы процесса.

## Формат конфига

Взят из `hiddify-sing-box` (`option.V2RayXHTTPOptions`) и повторяет Xray:
внутри блока `transport` поля идут в camelCase, а не в snake_case, как в
остальном конфиге sing-box.

```json
"transport": {
  "type": "xhttp",
  "mode": "auto",
  "host": "cdn.example.com",
  "path": "/xh",
  "headers": { "X-Test": "yes" },
  "scMaxEachPostBytes": 1000000,
  "noGRPCHeader": true,
  "downloadSettings": {
    "server": "dl.example.com",
    "server_port": 8443,
    "path": "/xh",
    "tls": { "enabled": true, "server_name": "dl.example.com",
             "utls": { "enabled": true, "fingerprint": "chrome" } }
  }
}
```

Всё, что лежит в параметре `extra` ссылки (это JSON в формате Xray),
переносится в блок как есть; `host` и `path` берутся из самой ссылки, если
в `extra` их нет. Отдельный канал скачивания (`downloadSettings`) переводится
из формата Xray (`address`/`port`/`security`/`tlsSettings`/`realitySettings`)
в формат ядра (`server`/`server_port`/`tls`).

## Как получить ядро с XHTTP

### Вариант 1 — через GitHub Actions (проще)

1. Actions → **Build sing-box core with XHTTP** → Run workflow.
2. `core_ref` — ревизия форка. По умолчанию `dd10a2129de7` (проверено, XHTTP
   в ней есть).
3. Скачать артефакт `libbox-xhttp-<ref>` — внутри `libbox.aar` (API 23+) и
   `libbox-legacy.aar` (API 21+).

### Вариант 2 — локально

Понадобятся Go (не ниже версии из `go.mod` ядра), JDK 17, Android SDK и NDK.

```bash
git clone https://github.com/hiddify/hiddify-sing-box.git
cd hiddify-sing-box && git checkout dd10a2129de7
go install -v github.com/sagernet/gomobile/cmd/gomobile@v0.1.11
go install -v github.com/sagernet/gomobile/cmd/gobind@v0.1.11
go run ./cmd/internal/build_libbox -target android   # -> libbox.aar
```

Это тот же способ, которым ядро собирает себя само (`make lib_android`), с
тем же пакетом `io.nekohasekai` — поэтому `.aar` подходит плагину
`flutter_singbox_client` без правок Kotlin-кода.

## Как подставить ядро, не трогая рабочую сборку

Плагин подключён git-зависимостью, и ядро лежит внутри него:

```yaml
# app/pubspec.yaml
flutter_singbox_client:
  git:
    url: https://github.com/Ghosts1996/cf.git
    ref: ccurecc_singbox_dns        # ветка с текущим ядром
    path: app/third_party/flutter_singbox_client
```

Поэтому переключение ядра — это переключение ветки, а не правка кода:

1. Создать ветку плагина от рабочей:
   `git checkout ccurecc_singbox_dns && git checkout -b ccurecc_singbox_xhttp`
2. Заменить в ней `app/third_party/flutter_singbox_client/android/libs/libbox.aar`
   собранным файлом, закоммитить и запушить.
3. В ветке приложения с XHTTP поменять `ref:` на `ccurecc_singbox_xhttp`.
4. `flutter pub get` (ревизия зафиксируется в `pubspec.lock`) и сборка APK.

Рабочая ветка приложения при этом продолжает ссылаться на прежнее ядро —
`ccurecc_singbox_dns` остаётся нетронутой. Откат = вернуть `ref:` обратно.

## Что проверить после подмены ядра

1. Обычные локации подключаются как раньше (это главное — форк отличается от
   апстрима не только XHTTP).
2. «Мои ключи» → «Проверить ключ»: XHTTP-локации должны перестать
   показываться в списке неподдерживаемых.
3. Подключение к XHTTP-локации поднимается и реально пропускает трафик.
4. Смена сервера на лету и замер задержки в списке серверов продолжают
   работать (они используют группу-селектор и `urlTest` ядра).

## Риски

- Форк Hiddify — это не апстрим: кроме XHTTP там свои патчи DNS, tailscale,
  psiphon и прочего. Поведение обычных подключений может отличаться, поэтому
  пункт 1 из проверки выше обязателен.
- Лицензия ядра остаётся GPL-3.0, как и у текущего.
- Размер APK вырастет: в форке больше протоколов.
