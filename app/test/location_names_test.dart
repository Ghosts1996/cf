import 'package:flutter_test/flutter_test.dart';
import 'package:vpnonline_app/services/location_names.dart';

void main() {
  String? find(List<String> candidates, String name,
          {List<String> known = const [], bool loose = true}) =>
      LocationNames.find(candidates, name, (s) => s,
          known: LocationNames.normalizedSet(known), loose: loose);

  test('невидимые символы эмодзи и лишние пробелы не мешают', () {
    // В подписке «⚡️» с вариационным селектором, на экране — без него.
    expect(find(['🇸🇪  ⚡️ Швеция '], '🇸🇪 ⚡ Швеция'),
        '🇸🇪  ⚡️ Швеция ');
  });

  test('«Мобильный интернет 1» — не «Мобильный интернет 11»', () {
    expect(find(['🇷🇺 Мобильный интернет 11'], '🇷🇺 Мобильный интернет 1'),
        isNull);
    expect(find(['🇷🇺 Мобильный интернет 1'], '🇷🇺 Мобильный интернет 11'),
        isNull);
  });

  test('«Германия №1» не находит «Германия №1 · gRPC», если это две локации',
      () {
    const subscription = ['Германия №1', 'Германия №1 · gRPC'];
    expect(find(['Германия №1 · gRPC'], 'Германия №1', known: subscription),
        isNull);
    expect(find(subscription, 'Германия №1', known: subscription),
        'Германия №1');
  });

  test('название сервиса через «|» — та же локация', () {
    expect(find(['VPNonLine | 🇩🇪 Германия — Франкфурт'],
            '🇩🇪 Германия — Франкфурт'),
        'VPNonLine | 🇩🇪 Германия — Франкфурт');
    expect(find(['🇩🇪 Германия'], 'VPNonLine | 🇩🇪 Германия'), '🇩🇪 Германия');
    expect(find(['🇬🇧 Англия | VPNonLine'], '🇬🇧 Англия'),
        '🇬🇧 Англия | VPNonLine');
  });

  test('«Нидерланды» и «Нидерланды | №1» — разные, если обе в подписке', () {
    const known = ['Нидерланды', 'Нидерланды | №1'];
    expect(find(['Нидерланды | №1'], 'Нидерланды', known: known), isNull);
  });

  test('пустое имя не совпадает ни с чем', () {
    // Раньше локация без имени «совпадала» со всеми: любая строка содержит
    // пустую, и весь список считался «в сессии» — «измеряю…» навсегда.
    expect(find([''], '🇷🇺 Мобильный интернет 4'), isNull);
    expect(find(['   '], 'Швеция'), isNull);
    expect(find(['Швеция'], ''), isNull);
  });

  test('несколько похожих — не угадываем', () {
    expect(find(['VPN | Швеция', 'Backup | Швеция'], 'Швеция'), isNull);
  });

  test('нестрогое сравнение — только отдельными словами и без него, если '
      'запрещено', () {
    expect(find(['🇬🇧 Англия [premium]'], '🇬🇧 Англия'), '🇬🇧 Англия [premium]');
    expect(find(['🇬🇧 Англия [premium]'], '🇬🇧 Англия', loose: false), isNull);
    expect(find(['Германия №10'], 'Германия №1'), isNull);
  });
}
