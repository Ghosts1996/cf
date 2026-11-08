/// Подпись пинга на главном экране и разделение списка локаций — чистые
/// функции без состояния экрана, чтобы их можно было проверить тестами.
library;

/// Чем раскрасить подпись: зелёным, обычным, предупреждением.
enum LatencyTone { good, dim, warn }

/// Подпись под кольцом на главном экране.
///
/// Раньше при выключенном VPN неудачный замер (сервер не ответил на
/// рукопожатие — например, у оператора «белые списки») оставлял подпись
/// «проверка соединения…» навсегда: обе ветки «ещё меряем» и «померили, но
/// числа нет» возвращали одно и то же. Теперь у каждого исхода своя подпись.
/// [ms] в ответе — число для начала подписи (или null), [text] — переводимая
/// часть (её экран пропускает через tr()).
({int? ms, String text, LatencyTone tone}) mainLatencyLabel({
  required bool checking,
  required bool probed,
  required int? ms,
  required bool connected,
  required bool hasKey,
}) {
  final value = (ms != null && ms > 0) ? ms : null;
  if (value != null) {
    if (value < 120) return (ms: value, text: 'мс · отличный сигнал', tone: LatencyTone.good);
    if (value < 300) return (ms: value, text: 'мс · стабильно', tone: LatencyTone.dim);
    return (ms: value, text: 'мс · медленно', tone: LatencyTone.warn);
  }
  if (connected) {
    // Туннель поднят, трафик идёт — числа просто ещё нет. «Не отвечает» здесь
    // пугало бы на ровном месте.
    return (ms: null, text: 'соединение активно', tone: LatencyTone.dim);
  }
  if (checking || !probed) {
    return (ms: null, text: 'проверка соединения…', tone: LatencyTone.dim);
  }
  if (!hasKey) return (ms: null, text: 'нет активного ключа', tone: LatencyTone.dim);
  return (ms: null, text: 'не ответил · подключу к рабочему', tone: LatencyTone.warn);
}

/// Делит отсортированный список локаций на те, что показываем сразу, и
/// «сейчас не отвечают» — их экран сворачивает в один пункт внизу.
///
/// [quiet] — для каждой локации: не отвечает / не в подписке / протокол не
/// поддерживается. [pinned] — выбранная, подключённая и избранные: их не
/// прячем никогда, даже если молчат.
///
/// Если молчат все, ничего не прячем: это скорее сеть телефона (например,
/// «белые списки» у оператора), чем все серверы разом, и пустой список
/// выглядел бы как поломка приложения.
/// Схлопывает точные дубли имени локации. Несколько панелей отдают одну и ту
/// же страну под одинаковым именем («🇩🇪 Германия» ×4): для пользователя это
/// одна локация (выбор на экране идёт по имени), а в списке — повтор флага и
/// одинаковые карточки, из-за которых казалось, что «серверов куча, но все
/// одинаковые». Оставляем первое вхождение каждого имени; если список уже
/// отсортирован по пингу — это самая быстрая из одноимённых.
///
/// [keep] — локации, которые нельзя схлопывать (выбранная / подключённая):
/// их пропускаем всегда, чтобы под рукой пользователя карточка не исчезла.
/// Пустые имена не трогаем — их не с чем сравнивать.
List<T> dedupByName<T>(
  List<T> list, {
  required String Function(T host) nameOf,
  bool Function(T host)? keep,
}) {
  final seen = <String>{};
  final out = <T>[];
  for (final host in list) {
    final name = nameOf(host);
    if (name.isEmpty) {
      out.add(host);
      continue;
    }
    final fresh = seen.add(name);
    if (fresh || (keep?.call(host) ?? false)) out.add(host);
  }
  return out;
}

({List<T> shown, List<T> hidden}) splitQuietHosts<T>(
  List<T> sorted, {
  required bool Function(T host) quiet,
  required bool Function(T host) pinned,
}) {
  final shown = <T>[];
  final hidden = <T>[];
  for (final host in sorted) {
    (quiet(host) && !pinned(host) ? hidden : shown).add(host);
  }
  final anyAlive = shown.any((h) => !quiet(h));
  if (!anyAlive || hidden.isEmpty) {
    return (shown: List<T>.of(sorted), hidden: <T>[]);
  }
  return (shown: shown, hidden: hidden);
}
