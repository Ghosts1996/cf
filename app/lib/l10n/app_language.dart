import 'package:flutter/material.dart';

/// [НОВОЕ] Модуль переводчика — список языков, которые реально доступны в
/// кнопке "Язык" на экране "Настройки". Раньше эта кнопка была нерабочей
/// декорацией (см. `settings_screen.dart`, строка с `_SettingsRow(label:
/// 'Язык', ...)`) — теперь она открывает выбор из этого списка.
///
/// Как добавить ещё один язык:
/// 1. Добавь новую константу сюда (код ISO 639-1 + человекочитаемое имя).
/// 2. Создай `lib/l10n/translations_xx.dart` с `Map<String, String>` —
///    ключ = оригинальная русская строка ИЗ КОДА (не придуманный id!),
///    значение = перевод. Смотри `translations_en.dart` как пример.
/// 3. Зарегистрируй карту в `AppTranslations.byLanguage` в
///    `lib/services/locale_service.dart`.
/// Экран настроек и вся остальная логика подхватят новый язык
/// автоматически — трогать их не нужно.
enum AppLanguage {
  ru('ru', 'Русский'),
  en('en', 'English');

  const AppLanguage(this.code, this.label);

  /// Код языка ISO 639-1 — используется и как ключ хранения в LocalPrefs,
  /// и как `Locale(code)` для MaterialApp.
  final String code;

  /// Имя языка, которое видит пользователь в списке выбора — ПИШЕТСЯ НА
  /// САМОМ ЭТОМ ЯЗЫКЕ (так делают все нормальные переключатели языка —
  /// "English" должен быть виден даже тому, кто не читает по-русски).
  final String label;

  Locale get locale => Locale(code);

  static AppLanguage fromCode(String? code) {
    return AppLanguage.values.firstWhere(
      (l) => l.code == code,
      orElse: () => AppLanguage.ru,
    );
  }
}
