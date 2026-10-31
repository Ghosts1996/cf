// Сопоставление имён локаций между подпиской, сессией ядра и экраном.
//
// Одна и та же локация приходит под немного разными именами: в remark
// VLESS-ссылки панель может дописать название сервиса («VPNonLine | 🇩🇪
// Германия»), а в эмодзи попадают невидимые символы (`⚡️` и `⚡` — это
// разные строки). Раньше имена сравнивались по вхождению подстроки, и на
// подписке из девяноста локаций это путало соседей: «Мобильный интернет 11»
// считался тем же, что «Мобильный интернет 1», у «Германия №1» показывался
// пинг «Германия №1 · gRPC», а локация с пустым именем «совпадала» со всеми
// сразу — и весь список висел на «измеряю…».

/// Правила сопоставления имён локаций.
class LocationNames {
  LocationNames._();

  // Вариационные селекторы эмодзи и символы нулевой ширины.
  static final _invisible = RegExp('[︎️​‌‍⁠﻿]');
  static final _spaces = RegExp(r'\s+');
  static final _wordChar = RegExp(r'[\p{L}\p{N}]', unicode: true);

  /// Имя в виде для сравнения: без невидимых символов, с одиночными
  /// пробелами, в нижнем регистре.
  static String normalize(String name) => name
      .replaceAll(_invisible, '')
      .replaceAll(_spaces, ' ')
      .trim()
      .toLowerCase();

  /// [long] — это [short] с названием сервиса через «|» спереди или сзади:
  /// «vpnonline | 🇩🇪 германия» и «🇩🇪 германия». Оба уже нормализованы.
  static bool _isTaggedForm(String long, String short) {
    if (long.length <= short.length) return false;
    if (long.endsWith(short)) {
      final head = long.substring(0, long.length - short.length).trimRight();
      if (head.endsWith('|')) return true;
    }
    if (long.startsWith(short)) {
      final tail = long.substring(short.length).trimLeft();
      if (tail.startsWith('|')) return true;
    }
    return false;
  }

  /// [long] содержит [short] отдельными словами: «мобильный интернет 11» не
  /// содержит «мобильный интернет 1» — после него идёт цифра.
  ///
  /// Номер сверх имени — другой сервер, а не то же имя подлиннее: «германия
  /// (2)» — второй сервер под именем «германия» (см.
  /// TunnelService.uniqueRemarks), и на экране он своя карточка.
  static bool _containsAsWords(String long, String short) {
    if (short.isEmpty || long.length <= short.length) return false;
    var from = 0;
    while (true) {
      final i = long.indexOf(short, from);
      if (i < 0) return false;
      final end = i + short.length;
      final beforeOk = i == 0 || !_wordChar.hasMatch(long[i - 1]);
      final afterOk = end >= long.length || !_wordChar.hasMatch(long[end]);
      if (beforeOk && afterOk) {
        final rest = long.substring(0, i) + long.substring(end);
        return !_numberOnly.hasMatch(rest);
      }
      from = i + 1;
    }
  }

  static final _numberOnly = RegExp(r'^[\s(#№]*\d+[\s)]*$');

  /// Та же локация, что [name], среди [candidates]; null — нет такой или
  /// подходят несколько.
  ///
  /// Порядок:
  ///  1. имя совпадает целиком (после [normalize]);
  ///  2. если имя дословно есть среди [known] (все имена подписки или
  ///     экрана), это отдельная локация, и нестрогие правила к ней не
  ///     применяются — иначе «Германия №1» нашлась бы в «Германия №1 · gRPC»;
  ///  3. одно имя — это другое с названием сервиса через «|»;
  ///  4. если [loose] — одно имя входит в другое отдельными словами.
  /// В шагах 3–4 подходящий кандидат должен быть ровно один, и кандидаты с
  /// именами из [taken] (нормализованными) в них не участвуют.
  static T? find<T>(
    Iterable<T> candidates,
    String name,
    String Function(T) nameOf, {
    Set<String> known = const <String>{},
    bool loose = true,
    Set<String> taken = const <String>{},
  }) {
    final needle = normalize(name);
    if (needle.isEmpty) return null;
    final items = <(T, String)>[];
    for (final candidate in candidates) {
      final normalized = normalize(nameOf(candidate));
      if (normalized.isEmpty) continue;
      if (normalized == needle) return candidate;
      // Кандидат, чьё имя дословно занято другим именем того же списка, —
      // не наш: «Англия» есть в подписке сама, и «Англия (через Москву)» с
      // ней не сливается.
      if (taken.contains(normalized)) continue;
      items.add((candidate, normalized));
    }
    if (known.contains(needle)) return null;

    T? single(bool Function(String) matches) {
      T? found;
      var count = 0;
      for (final (candidate, normalized) in items) {
        if (!matches(normalized)) continue;
        found = candidate;
        if (++count > 1) return null;
      }
      return found;
    }

    final tagged = single((other) =>
        _isTaggedForm(other, needle) || _isTaggedForm(needle, other));
    if (tagged != null || !loose) return tagged;
    return single((other) =>
        _containsAsWords(other, needle) || _containsAsWords(needle, other));
  }

  /// Нормализованные имена — для параметра `known` в [find].
  static Set<String> normalizedSet(Iterable<String> names) => {
        for (final name in names)
          if (normalize(name).isNotEmpty) normalize(name),
      };
}
