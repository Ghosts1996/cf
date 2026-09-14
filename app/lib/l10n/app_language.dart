import 'package:flutter/material.dart';

/// Языки, доступные в переключателе на экране "Настройки".
///
/// Чтобы добавить язык: завести здесь константу (ISO 639-1 + имя),
/// создать `lib/l10n/translations_xx.dart` с картой
/// `оригинальная русская строка -> перевод` и зарегистрировать её в
/// `AppTranslations.byLanguage` (`lib/services/locale_service.dart`).
enum AppLanguage {
  ru('ru', 'Русский'),
  en('en', 'English');

  const AppLanguage(this.code, this.label);

  /// Код языка ISO 639-1 — ключ хранения в LocalPrefs и `Locale(code)`
  /// для MaterialApp.
  final String code;

  /// Имя языка для списка выбора — на самом этом языке.
  final String label;

  Locale get locale => Locale(code);

  static AppLanguage fromCode(String? code) {
    return AppLanguage.values.firstWhere(
      (l) => l.code == code,
      orElse: () => AppLanguage.ru,
    );
  }
}
