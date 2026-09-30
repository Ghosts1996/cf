# Список блокировки рекламы

`assets/adblock/adblock.srs` — двоичный rule-set sing-box, ~60 тысяч доменов
(HaGeZi Multi PRO mini + v2fly category-ads-all + российские рекламные сети).
Приложение копирует его на диск (`lib/services/ad_block_rules.dart`), ядро
отвечает на DNS-запросы к этим доменам «нет такого домена» и отклоняет
соединения с ними.

Обновить список: `python3 tool/adblock/build.py /путь/к/sing-box` из папки
`app/`, ядром из плагина. Потом — `flutter test test/ad_block_test.dart`.
