import 'package:flutter/foundation.dart';
import '../l10n/app_language.dart';
import '../l10n/translations_en.dart' as en;
import 'local_prefs.dart';

/// [НОВОЕ] Модуль переводчика — ядро.
///
/// Как это устроено (специально без сторонних пакетов вроде `easy_localization`
/// или официального `flutter gen-l10n`/ARB — их генератор требует шаг
/// кодогенерации при сборке, который негде было прогнать и проверить в
/// этой среде; ниже — обычный Dart, ничего не генерируется):
///
/// 1. Весь интерфейс как был написан на русском текстом прямо в виджетах
///    (`Text('Настройки')`) — так и остаётся. Русский текст остаётся
///    единственным источником правды.
/// 2. Каждая такая строка оборачивается в `tr('Настройки')` — если текущий
///    язык русский (или в словаре перевода не нашлось), `tr()` вернёт
///    строку как есть; если выбран другой язык — вернёт перевод из
///    соответствующей карты (см. lib/l10n/translations_en.dart).
/// 3. `LocaleService` — обычный `ChangeNotifier`-синглтон (тот же паттерн,
///    что и `TunnelService`/`ApiClient` в этом репозитории): хранит
///    текущий `AppLanguage`, persist через `LocalPrefs` (переживает
///    перезапуск приложения — та же история багов, что описана в докстринге
///    самого `LocalPrefs`), и уведомляет `main.dart`, когда язык меняется.
///
/// Кнопка "Язык" на экране "Настройки" вызывает [setLanguage] — дальше всё
/// происходит само: `AnimatedBuilder` в `main.dart` перестраивает
/// `MaterialApp` с новой `Locale`.
class LocaleService extends ChangeNotifier {
  LocaleService._();
  static final LocaleService instance = LocaleService._();

  /// [НОВОЕ] Здесь регистрируются все языки, для которых есть карта
  /// переводов. Русский не нуждается в карте — это исходный язык кода.
  /// Добавляя новый язык (см. докстринг в app_language.dart), добавь его
  /// карту сюда одной строкой.
  static final Map<AppLanguage, Map<String, String>> _dictionaries = {
    AppLanguage.en: en.translationsEn,
  };

  AppLanguage _language = AppLanguage.ru;
  AppLanguage get language => _language;

  bool _loaded = false;
  Future<void>? _loadFuture;

  /// Дожидается, пока сохранённый язык прочитается из LocalPrefs. Вызывается
  /// один раз в main() до runApp() — см. докстринг там же.
  Future<void> ensureLoaded() {
    return _loadFuture ??= _load();
  }

  Future<void> _load() async {
    final saved = await LocalPrefs.instance.getString(PrefKeys.appLanguage);
    _language = AppLanguage.fromCode(saved);
    _loaded = true;
    notifyListeners();
  }

  /// Вызывается кнопкой "Язык" на экране "Настройки".
  Future<void> setLanguage(AppLanguage value) async {
    if (_language == value) return;
    _language = value;
    notifyListeners();
    await LocalPrefs.instance.setString(PrefKeys.appLanguage, value.code);
  }

  /// Переводит [russianText] (исходная строка из кода) на текущий язык.
  /// Если текущий язык — русский, или перевода для этой конкретной строки
  /// ещё нет в карте (см. REPORT_TRANSLATOR.md — не весь текст приложения
  /// переведён за один заход), возвращает исходную строку без изменений —
  /// пользователь никогда не увидит пустое место или ключ вместо текста.
  String translate(String russianText) {
    if (_language == AppLanguage.ru) return russianText;
    final dict = _dictionaries[_language];
    if (dict == null) return russianText;
    return dict[russianText] ?? russianText;
  }
}

/// Короткий глобальный хелпер — короче, чем писать
/// `LocaleService.instance.translate(...)` в каждом виджете.
/// Использование: `Text(tr('Настройки'))` вместо `Text('Настройки')`.
String tr(String russianText) => LocaleService.instance.translate(russianText);