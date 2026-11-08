import 'package:flutter_test/flutter_test.dart';
import 'package:vpnonline_app/services/latency_label.dart';

void main() {
  group('подпись пинга на главном экране', () {
    test('VPN выключен, замер прошёл без числа — не «проверка…» навсегда', () {
      final st = mainLatencyLabel(
          checking: false, probed: true, ms: null, connected: false, hasKey: true);
      expect(st.text, 'не ответил · подключу к рабочему');
      expect(st.tone, LatencyTone.warn);
    });

    test('ноль и отрицательное — не число, а его отсутствие', () {
      for (final ms in [0, -1]) {
        final st = mainLatencyLabel(
            checking: false, probed: true, ms: ms, connected: false, hasKey: true);
        expect(st.ms, isNull);
        expect(st.text, isNot(contains('проверка')));
      }
    });

    test('пока меряем — «проверка соединения…»', () {
      final st = mainLatencyLabel(
          checking: true, probed: false, ms: null, connected: false, hasKey: true);
      expect(st.text, 'проверка соединения…');
    });

    test('VPN включён, числа ещё нет — «соединение активно», без мигания «проверки»', () {
      final st = mainLatencyLabel(
          checking: true, probed: false, ms: null, connected: true, hasKey: true);
      expect(st.text, 'соединение активно');
    });

    test('нет ключа — так и написано', () {
      final st = mainLatencyLabel(
          checking: false, probed: true, ms: null, connected: false, hasKey: false);
      expect(st.text, 'нет активного ключа');
    });

    test('пороги: отлично / стабильно / медленно', () {
      expect(mainLatencyLabel(checking: false, probed: true, ms: 70, connected: true, hasKey: true),
          (ms: 70, text: 'мс · отличный сигнал', tone: LatencyTone.good));
      expect(mainLatencyLabel(checking: false, probed: true, ms: 180, connected: true, hasKey: true).text,
          'мс · стабильно');
      expect(mainLatencyLabel(checking: false, probed: true, ms: 450, connected: false, hasKey: true).tone,
          LatencyTone.warn);
    });

    test('число показывается и во время перепроверки', () {
      final st = mainLatencyLabel(
          checking: true, probed: false, ms: 95, connected: true, hasKey: true);
      expect(st.ms, 95);
    });
  });

  group('неотвечающие локации сворачиваются', () {
    // имя → молчит ли
    final quietSet = {'Литва', 'ЮАР', 'Швеция'};
    List<String> all = ['Англия', 'Турция', 'Литва', 'ЮАР', 'Швеция'];

    test('рабочие — сразу, молчащие — под пунктом', () {
      final r = splitQuietHosts<String>(all,
          quiet: quietSet.contains, pinned: (_) => false);
      expect(r.shown, ['Англия', 'Турция']);
      expect(r.hidden, ['Литва', 'ЮАР', 'Швеция']);
    });

    test('выбранную/подключённую/избранную не прячем, даже если молчит', () {
      final r = splitQuietHosts<String>(all,
          quiet: quietSet.contains, pinned: (h) => h == 'Литва');
      expect(r.shown, ['Англия', 'Турция', 'Литва']);
      expect(r.hidden, ['ЮАР', 'Швеция']);
    });

    test('молчат все — это сеть телефона, показываем всё', () {
      final r = splitQuietHosts<String>(['Литва', 'ЮАР'],
          quiet: (_) => true, pinned: (_) => false);
      expect(r.shown, ['Литва', 'ЮАР']);
      expect(r.hidden, isEmpty);
    });

    test('молчит только закреплённая — тоже показываем всё как есть', () {
      final r = splitQuietHosts<String>(['Литва', 'ЮАР'],
          quiet: (_) => true, pinned: (h) => h == 'Литва');
      expect(r.hidden, isEmpty);
      expect(r.shown, ['Литва', 'ЮАР']);
    });

    test('порядок сохраняется', () {
      final r = splitQuietHosts<String>(['A', 'x1', 'B', 'x2', 'C'],
          quiet: (h) => h.startsWith('x'), pinned: (_) => false);
      expect(r.shown, ['A', 'B', 'C']);
      expect(r.hidden, ['x1', 'x2']);
    });
  });

  group('дубли имени локации схлопываются', () {
    test('четыре одинаковые «Германии» → одна (первая по пингу)', () {
      final r = dedupByName<String>(
          ['🇩🇪 Германия', '🇫🇷 Франция', '🇩🇪 Германия', '🇩🇪 Германия'],
          nameOf: (h) => h);
      expect(r, ['🇩🇪 Германия', '🇫🇷 Франция']);
    });

    test('разные варианты одной страны остаются (БС/⚡ — отдельные локации)',
        () {
      final r = dedupByName<String>(
          ['🇩🇪 Германия', '🇩🇪 Германия • БС', '🇩🇪 Германия ⚡'],
          nameOf: (h) => h);
      expect(r, ['🇩🇪 Германия', '🇩🇪 Германия • БС', '🇩🇪 Германия ⚡']);
    });

    test('выбранную/подключённую карточку не схлопываем, даже если имя '
        'повторяется', () {
      // Вторая «Германия» — подключённая: оставляем обе, чтобы она не пропала.
      final items = [
        {'name': '🇩🇪 Германия', 'id': 'a'},
        {'name': '🇩🇪 Германия', 'id': 'b'},
      ];
      final r = dedupByName<Map<String, String>>(items,
          nameOf: (h) => h['name']!, keep: (h) => h['id'] == 'b');
      expect(r.map((h) => h['id']), ['a', 'b']);
    });

    test('пустые имена не трогаем', () {
      final r = dedupByName<String>(['', '', '🇫🇷 Франция'], nameOf: (h) => h);
      expect(r, ['', '', '🇫🇷 Франция']);
    });

    test('порядок сохраняется', () {
      final r = dedupByName<String>(['A', 'B', 'A', 'C', 'B'], nameOf: (h) => h);
      expect(r, ['A', 'B', 'C']);
    });
  });
}
