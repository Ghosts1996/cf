import 'package:flutter_test/flutter_test.dart';
import 'package:vpnonline_app/screens/servers_screen.dart';

void main() {
  // Панели отдают локации вперемешку. Список должен читаться сверху вниз как
  // «лучшее первым», а недоступное — оседать вниз.
  ({int group, int ms}) alive(int ms) => serverSortRank(
        unsupportedProtocol: false,
        inSubscription: true,
        subscriptionKnown: true,
        corePing: ms,
      );

  final measuring = serverSortRank(
      unsupportedProtocol: false, inSubscription: true, subscriptionKnown: true);
  final dead = serverSortRank(
      unsupportedProtocol: false,
      inSubscription: true,
      subscriptionKnown: true,
      checkFailed: true);
  final notInSubscription = serverSortRank(
      unsupportedProtocol: false, inSubscription: false, subscriptionKnown: true);
  final unsupported = serverSortRank(unsupportedProtocol: true);

  test('быстрый сервер выше медленного', () {
    expect(alive(70).group, alive(300).group);
    expect(alive(70).ms, lessThan(alive(300).ms));
  });

  test('живой выше того, что ещё меряется, а тот — выше мёртвого', () {
    expect(alive(900).group, lessThan(measuring.group));
    expect(measuring.group, lessThan(dead.group));
  });

  test('недоступное оседает вниз в понятном порядке', () {
    expect(dead.group, lessThan(notInSubscription.group));
    expect(notInSubscription.group, lessThan(unsupported.group));
  });

  test('помеченный «не отвечает» уходит вниз, даже если от прошлой проверки '
      'осталось быстрое число', () {
    // Скриншот 23.10: наверху списка стояли «⚡ Швеция», «⚡ Германия»… с
    // подписью «не отвечает» — по их числам многочасовой давности.
    final markedDead = serverSortRank(
        unsupportedProtocol: false,
        inSubscription: true,
        subscriptionKnown: true,
        dead: true,
        corePing: 41);
    expect(markedDead.group, dead.group);
    expect(alive(900).group, lessThan(markedDead.group));
    expect(measuring.group, lessThan(markedDead.group));
  });

  test('число прошлой проверки: среди ещё не измеренных — первым, но ниже '
      'измеренных сейчас', () {
    // 31.10: клиент открывал приложение через пару часов и видел
    // «проверяю…» на всех карточках — рабочие серверы было не отличить.
    ({int group, int ms}) was(int ms) => serverSortRank(
        unsupportedProtocol: false,
        inSubscription: true,
        subscriptionKnown: true,
        previousPing: ms);
    expect(was(80).group, measuring.group);
    expect(was(80).ms, lessThan(measuring.ms));
    expect(was(80).ms, lessThan(was(300).ms));
    expect(alive(900).group, lessThan(was(80).group));
    // Свежий отказ важнее прошлого числа.
    expect(
        serverSortRank(
                unsupportedProtocol: false,
                inSubscription: true,
                subscriptionKnown: true,
                checkFailed: true,
                previousPing: 80)
            .group,
        dead.group);
  });

  test('весь список выстраивается как ожидается', () {
    final rows = <String, ({int group, int ms})>{
      'Япония 330': alive(330),
      'Германия 70': alive(70),
      'не отвечает': dead,
      'протокол не наш': unsupported,
      'Латвия 95': alive(95),
      'меряется': measuring,
      'нет в подписке': notInSubscription,
    };
    final sorted = rows.entries.toList()
      ..sort((a, b) => a.value.group != b.value.group
          ? a.value.group.compareTo(b.value.group)
          : a.value.ms.compareTo(b.value.ms));
    expect(sorted.map((e) => e.key), [
      'Германия 70',
      'Латвия 95',
      'Япония 330',
      'меряется',
      'не отвечает',
      'нет в подписке',
      'протокол не наш',
    ]);
  });
}
