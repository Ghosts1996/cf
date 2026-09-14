import 'package:flutter/foundation.dart';
import '../l10n/app_language.dart';
import '../l10n/translations_en.dart' as en;
import 'local_prefs.dart';

/// Локализация интерфейса.
///
/// Сделано без сторонних пакетов и без кодогенерации ARB:
///
/// 1. Русский текст в виджетах остаётся единственным источником правды.
/// 2. Строка оборачивается в `tr('Настройки')`: для русского (или когда
///    перевода нет) вернётся она же, иначе — значение из карты
///    (lib/l10n/translations_en.dart).
/// 3. LocaleService — ChangeNotifier-синглтон: хранит текущий язык,
///    сохраняет его через LocalPrefs и уведомляет main.dart о смене.
///
/// Кнопка "Язык" вызывает [setLanguage], после чего AnimatedBuilder в
/// main.dart перестраивает MaterialApp с новой Locale.
class LocaleService extends ChangeNotifier {
  LocaleService._();
  static final LocaleService instance = LocaleService._();

  /// Все языки, для которых есть карта переводов. Русскому карта не нужна —
  /// это исходный язык кода.
  static final Map<AppLanguage, Map<String, String>> _dictionaries = {
    AppLanguage.en: en.translationsEn,
  };

  AppLanguage _language = AppLanguage.ru;
  AppLanguage get language => _language;

  Future<void>? _loadFuture;

  /// Дожидается, пока сохранённый язык прочитается из LocalPrefs.
  /// Вызывается один раз в main() до runApp().
  Future<void> ensureLoaded() {
    return _loadFuture ??= _load();
  }

  Future<void> _load() async {
    final saved = await LocalPrefs.instance.getString(PrefKeys.appLanguage);
    _language = AppLanguage.fromCode(saved);
    notifyListeners();
  }

  /// Вызывается кнопкой "Язык" на экране "Настройки".
  Future<void> setLanguage(AppLanguage value) async {
    if (_language == value) return;
    _language = value;
    notifyListeners();
    await LocalPrefs.instance.setString(PrefKeys.appLanguage, value.code);
  }

  /// Переводит [russianText] на текущий язык. Для русского языка и для
  /// строк, которых ещё нет в карте, возвращает исходный текст — вместо
  /// текста никогда не появится пустое место или ключ.
  String translate(String russianText) {
    if (_language == AppLanguage.ru) return russianText;
    final dict = _dictionaries[_language];
    if (dict == null) return russianText;
    return dict[russianText] ?? russianText;
  }
}

/// Короткий хелпер: `Text(tr('Настройки'))`.
String tr(String russianText) => LocaleService.instance.translate(russianText);