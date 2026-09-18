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

Всё собрано и разложено автоматически — workflow
`.github/workflows/build-xhttp-core.yml` не просто отдаёт `.aar` артефактом,
а сам кладёт его в отдельную ветку плагина.

### Что делает workflow

1. Клонирует `hiddify/hiddify-sing-box` на прибитом коммите
   `8d94f44` (ветка по умолчанию у форка называется `extended`, не `main`).
2. Собирает `libbox.aar` тем же `gomobile bind` и с теми же тегами, что и
   `cmd/internal/build_libbox` самого ядра: пакет `io.nekohasekai`,
   `-androidapi 23`, `-libname=box`. Поэтому `.aar` подходит плагину
   `flutter_singbox_client` без единой правки Kotlin-кода.
3. Проверяет собранную библиотеку на наличие режимов XHTTP (`stream-one` и
   остальные) — иначе сборка падает, а не выкладывает тихо непригодное ядро.
4. Проверяет размер: GitHub отклоняет push с файлом больше 100 МБ.
5. Создаёт (или обновляет) ветку `ccurecc_singbox_xhttp` — копию рабочей
   `ccurecc_singbox_dns`, отличающуюся ровно одним файлом,
   `android/libs/libbox.aar`.

### Архитектуры

По умолчанию собираются только `android/arm64` и `android/arm`: на них
работают все телефоны, а каждая лишняя архитектура добавляет к `.aar`
примерно четверть его размера — с четырьмя файл упирается в лимит GitHub.
Эмуляторы x86_64 при таком ядре работать не будут; нужны — задай
`abis: android/arm64,android/arm,android/amd64` при ручном запуске и следи за
размером.

### Как запустить

Файл лежит не в ветке по умолчанию, а GitHub показывает кнопку «Run workflow»
только для workflow из неё. Поэтому основной триггер здесь — push, который
меняет сам файл workflow в ветке `claude/xhttp-support`: достаточно тронуть
комментарий «Пересборка №» в его шапке и запушить. Если файл когда-нибудь
попадёт в ветку по умолчанию, заработает и обычный `workflow_dispatch` с теми
же параметрами.

### Локально

Понадобятся Go (не ниже версии из `go.mod` ядра), JDK 17, Android SDK и NDK.

```bash
git clone https://github.com/hiddify/hiddify-sing-box.git
cd hiddify-sing-box && git checkout 8d94f44
go install -v github.com/sagernet/gomobile/cmd/gomobile@v0.1.12
go install -v github.com/sagernet/gomobile/cmd/gobind@v0.1.12
go run ./cmd/internal/build_libbox -target android   # -> libbox.aar
```

## Как ядро подключается к приложению

Плагин подключён git-зависимостью, и ядро лежит внутри него:

```yaml
# app/pubspec.yaml
flutter_singbox_client:
  git:
    url: https://github.com/Ghosts1996/cf.git
    ref: ccurecc_singbox_xhttp     # ядро с XHTTP (собрано workflow'ом)
    path: app/third_party/flutter_singbox_client
```

Переключение ядра — это переключение ветки, а не правка кода. Рабочая ветка
приложения (`claude/repository-analysis-5xv6jp`) продолжает ссылаться на
`ccurecc_singbox_dns` с прежним ядром, и она не меняется вовсе. Откат для
ветки с XHTTP — вернуть `ref:` обратно на `ccurecc_singbox_dns` и выполнить
`flutter pub get`.

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
