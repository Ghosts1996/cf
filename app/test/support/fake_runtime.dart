import 'dart:async';

import 'package:flutter_singbox_client/flutter_singbox_client.dart'
    show OutboundGroup, OutboundGroupItem, SessionOptions;
import 'package:vpnonline_app/services/singbox_runtime.dart';

/// Управляемая заглушка нативного ядра.
///
/// Ведёт себя как настоящий плагин на Android: шлёт `stopped / starting /
/// started / stopping` в [serviceStateStream], отвечает на getServiceState()
/// последним состоянием и записывает всё, что с ней делали. Сценарий
/// задаётся полями: сколько ядро поднимается, поднимается ли вообще, что
/// ответить на getServiceState() в обход потока.
class FakeRuntime implements SingboxRuntimeClient {
  final _state = StreamController<dynamic>.broadcast();
  final _stats = StreamController<dynamic>.broadcast();
  final _fault = StreamController<dynamic>.broadcast();
  final _coreLog = StreamController<dynamic>.broadcast();
  final _groups = StreamController<dynamic>.broadcast();

  /// Сколько ядро «поднимается» после connect().
  Duration startDelay = const Duration(milliseconds: 30);

  /// Поднимется ли ядро вообще. false — connect() отработает, но
  /// «started» так и не придёт: так выглядит зависший сервис.
  bool willStart = true;

  /// Что сейчас работает на самом деле.
  String current = 'ServiceState.stopped';

  /// Подмена ответа getServiceState(): так выглядит VPN, выключенный из
  /// шторки, — событие до приложения не дошло, а сервиса уже нет.
  String? stateOverride;

  final List<String> calls = [];
  int connectCount = 0;
  int disconnectCount = 0;
  final List<String> selected = [];

  /// Сколько сессий подняты одновременно. Больше одной — это ровно та
  /// гонка, из-за которой «через раз запускается».
  int liveSessions = 0;
  int maxLiveSessions = 0;

  void _emit(String s) {
    current = s;
    _state.add(s);
  }

  /// Строки журнала ядра — как их присылает плагин.
  void emitCoreLog(List<dynamic> entries) => _coreLog.add(entries);

  /// Ядро упало само — сеть пропала, Android усыпил сервис.
  void simulateDrop() {
    liveSessions = 0;
    _emit('ServiceState.stopped');
  }

  @override
  Future<void> initialize() async => calls.add('initialize');

  @override
  Stream<dynamic> get serviceStateStream => _state.stream;
  @override
  Stream<dynamic> get trafficStatsStream => _stats.stream;
  @override
  Stream<dynamic> get faultStream => _fault.stream;
  @override
  Stream<dynamic> get coreLogStream => _coreLog.stream;
  @override
  Stream<dynamic> get outboundGroupStream => _groups.stream;

  /// Хвост прошлой сессии: плагин отвечает «работает», пока его не
  /// попросят остановиться.
  bool leftoverSession = false;

  @override
  Future<dynamic> getServiceState() async =>
      leftoverSession ? 'ServiceState.started' : (stateOverride ?? current);

  @override
  Future<dynamic> getTrafficStats() async => const <String, dynamic>{};

  @override
  Future<void> checkConfig(String config) async => calls.add('checkConfig');

  /// Последний конфиг, который приложение отдало ядру, — ровно то, что на
  /// телефоне ушло бы в sing-box. Из тестов его выгружают на диск и гоняют
  /// настоящим ядром.
  String? lastConfig;

  /// Сколько следующих стартов ядро провалит с этим сообщением, как плагин:
  /// «starting», затем сообщение в faultStream и «stopped». Так выглядит
  /// старт, пока прошлое ядро ещё держит служебный порт.
  int failNextStarts = 0;
  String failMessage = 'Start failed: listen command server: listen tcp '
      '127.0.0.1:10086: bind: address already in use';

  @override
  Future<void> connect(SessionOptions options) async {
    calls.add('connect');
    lastConfig = options.config;
    connectCount++;
    liveSessions++;
    if (liveSessions > maxLiveSessions) maxLiveSessions = liveSessions;
    _emit('ServiceState.starting');
    if (failNextStarts > 0) {
      failNextStarts--;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      _fault.add(failMessage);
      liveSessions--;
      _emit('ServiceState.stopped');
      return;
    }
    if (!willStart) return;
    await Future<void>.delayed(startDelay);
    _emit('ServiceState.started');
  }

  @override
  Future<void> disconnect() async {
    leftoverSession = false;
    calls.add('disconnect');
    disconnectCount++;
    if (liveSessions > 0) liveSessions--;
    _emit('ServiceState.stopping');
    await Future<void>.delayed(const Duration(milliseconds: 10));
    _emit('ServiceState.stopped');
  }

  @override
  Future<bool> requestVPNPermission() async => true;

  @override
  Future<void> selectOutbound(String groupTag, String outboundTag) async {
    calls.add('select:$outboundTag');
    selected.add(outboundTag);
  }

  /// Что ядро ответит на замер задержки группы: `{'out-1': 40}`. Кого нет в
  /// списке — тот не ответил.
  Map<String, int> groupDelays = {};

  int closeAllCount = 0;

  @override
  Future<void> closeAllConnections() async {
    calls.add('closeAll');
    closeAllCount++;
  }

  @override
  Future<void> urlTest(String groupTag) async {
    calls.add('urlTest');
    if (groupDelays.isEmpty) return;
    Timer(const Duration(milliseconds: 30), () {
      _groups.add([
        OutboundGroup(tag: groupTag, type: 'urltest', items: [
          for (final e in groupDelays.entries)
            OutboundGroupItem(tag: e.key, type: 'vless', urlTestDelayMs: e.value),
        ]),
      ]);
    });
  }
}
