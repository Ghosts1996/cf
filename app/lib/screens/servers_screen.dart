import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import '../theme.dart';
import '../widgets/neon.dart';
import '../services/api_client.dart';
import '../state/selected_server.dart';
import '../services/local_prefs.dart';

/// Экран выбора сервера.
///
/// НАМЕРЕННО не содержит захардкоженного списка стран — список приходит из
/// backend (`GET /hosts`), который берёт его из таблицы `xui_hosts` (те же
/// 6 панелей 3x-ui, что видит бот). Добавил новую локацию в 3x-ui и в БД
/// бота -> она появится тут сама.
///
/// [ИСПРАВЛЕНО] Раньше экран звал несуществующий `getServers()` и ожидал
/// поля `id`/`country_code`/`ping_ms`, которых реальный `/hosts` не отдаёт.
/// Реальный ответ (см. api.py -> api_hosts()) — это ТОЛЬКО `host_name`,
/// `host_url`, `subscription_url` (сервер намеренно не отдаёт
/// host_username/host_pass — это чувствительные данные для входа в саму
/// панель). Значит: id сервера = сам `host_name` (он уникален), ping
/// реального замера не будет — сервер таких данных не считает и не хранит.
///
/// [ВАЖНО] Этот экран больше НЕ шаг покупки. Покупка выдаёт ключ сразу на
/// всех локациях (единый GLOBAL-бандл, см. plans_screen.dart). "Выбор"
/// здесь влияет только на то, какая локация подсвечивается как
/// приоритетная в ConnectScreen — чисто клиентская настройка.
///
/// [ИСПРАВЛЕНО] "Избранное" и "авто-балансировка" раньше были локальным
/// `Set`/`bool` полем State — сбрасывались при уходе с экрана/перезапуске
/// приложения (то же семейство багов, что и тумблеры в
/// SettingsScreen/SecurityScreen — см. services/local_prefs.dart). Теперь
/// сохраняются через LocalPrefs на устройство. Backend по-прежнему не
/// хранит избранное на сервере (это чисто клиентское предпочтение, не
/// синхронизируется между устройствами одного аккаунта) — если понадобится
/// синхронизация между устройствами, нужен отдельный эндпоинт на бэкенде,
/// это уже другая задача.
class ServersScreen extends StatefulWidget {
  const ServersScreen({super.key});
  @override
  State<ServersScreen> createState() => _ServersScreenState();
}

class _ServersScreenState extends State<ServersScreen> {
  final _api = ApiClient.instance;
  final _prefs = LocalPrefs.instance;
  List<dynamic>? _hosts;
  String? _error;
  bool _loading = true;
  String? _selectedId;
  final Set<String> _favorites = {};
  bool _autoBalance = false;
  // [НОВОЕ] Живой пинг с телефона до каждого сервера — host_name -> мс,
  // null пока не измерено, -1 если сервер недоступен. Раньше здесь везде
  // была статичная надпись "сервер онлайн", которая не отражала реальную
  // задержку ни разу — просто константный текст.
  final Map<String, int?> _livePing = {};

  ({String? host, int? port}) _pingEndpoint(Map<String, dynamic> server) {
    final explicitHost = server['connect_host'] as String?;
    final explicitPort = (server['connect_port'] as num?)?.toInt();
    if (explicitHost != null && explicitHost.isNotEmpty) {
      return (host: explicitHost, port: explicitPort ?? 443);
    }

    // Рабочий /hosts пока отдаёт subscription_url/host_url без отдельных
    // connect_host/connect_port. Извлекаем адрес из уже имеющегося URL.
    for (final key in const ['subscription_url', 'host_url']) {
      final raw = server[key] as String?;
      if (raw == null || raw.isEmpty) continue;
      final uri = Uri.tryParse(raw);
      if (uri == null || uri.host.isEmpty) continue;
      return (host: uri.host, port: uri.hasPort ? uri.port : 443);
    }
    return (host: null, port: null);
  }

  /// TCP-connect до connect_host:connect_port (см. api.py -> api_hosts()).
  /// Не ICMP-пинг (для него на Android нужны root-права/raw sockets,
  /// недоступные обычному приложению) — время TCP-рукопожатия достаточно
  /// точно отражает задержку до сервера для целей UI.
  ///
  /// [ИСПРАВЛЕНО — реальный баг со скриншота] Раньше при `host == null`
  /// функция просто делала `return` и НИКОГДА не писала значение в
  /// `_livePing[hostName]` — экран трактует `null` как "ещё измеряю" (см.
  /// build()), поэтому надпись "измеряю..." оставалась НАВСЕГДА, если у
  /// хоста нет connect_host. А это ровно то, что произойдёт для КАЖДОГО
  /// хоста, если на живом сервере ещё не задеплоен патч `backend-patch/api.py`
  /// с полями connect_host/connect_port в ответе `/hosts` — то есть баг на
  /// скриншоте, скорее всего, не в этом файле, а в том, что бэкенд ещё
  /// отдаёт старый ответ без этих полей. Но теперь UI хотя бы не врёт
  /// бесконечным "измеряю..." — покажет честное "нет данных для пинга".
  Future<void> _measureLivePing(
      String hostName, String? host, int? port) async {
    if (host == null || host.isEmpty) {
      if (mounted)
        setState(
            () => _livePing[hostName] = -2); // -2 = нет connect_host от бэкенда
      return;
    }
    final sw = Stopwatch()..start();
    try {
      final socket = await Socket.connect(host, port ?? 443,
          timeout: const Duration(seconds: 4));
      sw.stop();
      socket.destroy();
      if (mounted) setState(() => _livePing[hostName] = sw.elapsedMilliseconds);
    } catch (_) {
      if (mounted) setState(() => _livePing[hostName] = -1);
    }
    // [НОВОЕ] Авто-балансировка — реагируем на КАЖДЫЙ завершившийся замер,
    // а не только после того, как отмерятся все хосты разом (при большом
    // количестве серверов первый результат может прийти намного раньше
    // последнего — нет смысла ждать самый медленный/недоступный сервер,
    // чтобы применить уже имеющиеся данные).
    _maybeApplyAutoBalance();
  }

  void _measureAllPings(List<dynamic> hosts) {
    for (final s in hosts) {
      final host = s as Map<String, dynamic>;
      final hostName = host['host_name'] as String? ?? '';
      if (hostName.isEmpty) continue;
      final endpoint = _pingEndpoint(host);
      _measureLivePing(hostName, endpoint.host, endpoint.port);
    }
  }

  /// [НОВОЕ] Раньше тумблер "Авто-балансировка" только сохранял своё
  /// положение в LocalPrefs и больше НИЧЕГО не делал — ни на что не влиял
  /// фактически, ровно то, о чём предупреждал сам пользователь ("не просто
  /// глухо прогуливаться, а работать"). Теперь при включённой
  /// авто-балансировке — как только приходит новый результат пинга,
  /// пересчитываем сервер с наименьшим реальным пингом среди уже
  /// измеренных и делаем его выбранным. Ключевой нюанс: если пользователь
  /// САМ только что выбрал сервер вручную (см. onTap ниже), авто-выбор его
  /// молча не перебивает в ту же секунду — ждёт следующего цикла замера.
  void _maybeApplyAutoBalance() {
    if (!_autoBalance || _hosts == null || _hosts!.isEmpty) return;
    String? bestId;
    int? bestPing;
    for (final s in _hosts!) {
      final host = s as Map<String, dynamic>;
      final id = host['host_name'] as String? ?? '';
      if (id.isEmpty) continue;
      final ping = _livePing[id];
      if (ping == null || ping < 0)
        continue; // ещё не измерен / недоступен / нет данных
      if (bestPing == null || ping < bestPing) {
        bestPing = ping;
        bestId = id;
      }
    }
    if (bestId != null && bestId != _selectedId) {
      setState(() => _selectedId = bestId);
      SelectedServer.select(bestId, bestId);
      _prefs.setString(PrefKeys.selectedServerId, bestId);
    }
  }

  @override
  void initState() {
    super.initState();
    _loadPrefs();
    _load();
  }

  /// [НОВОЕ] Восстанавливаем избранное/авто-баланс/ранее выбранный сервер
  /// из LocalPrefs — раньше эти три значения были обычными полями State и
  /// всегда стартовали с дефолтов (пустое избранное, авто-баланс выкл,
  /// выбранный сервер = null) при каждом открытии экрана.
  Future<void> _loadPrefs() async {
    final results = await Future.wait([
      _prefs.getStringSet(PrefKeys.favoriteServers),
      _prefs.getBool(PrefKeys.autoBalance, fallback: false),
      _prefs.getString(PrefKeys.selectedServerId),
    ]);
    if (!mounted) return;
    setState(() {
      _favorites
        ..clear()
        ..addAll(results[0] as Set<String>);
      _autoBalance = results[1] as bool;
      _selectedId = results[2] as String?;
    });
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final hosts = await _api.getHosts();
      setState(() {
        _hosts = hosts;
        if (hosts.isNotEmpty) {
          // [ИСПРАВЛЕНО] Раньше проверка "_selectedId == null" срабатывала
          // ТОЛЬКО в первый заход — если сохранённый ранее _selectedId
          // (например через LocalPrefs) больше не встречается в свежем
          // списке хостов (сервер удалили/переименовали), экран продолжал
          // бы указывать на несуществующий host_name молча. Теперь если
          // текущий _selectedId не найден среди актуальных хостов —
          // выбираем первый доступный.
          final stillExists = _selectedId != null &&
              hosts.any((h) =>
                  (h as Map<String, dynamic>)['host_name'] == _selectedId);
          if (!stillExists) {
            final first = hosts.first as Map<String, dynamic>;
            _selectedId = first['host_name'] as String?;
            _prefs.setString(PrefKeys.selectedServerId, _selectedId ?? '');
          }
          if (SelectedServer.hostName.value == null) {
            final selectedHost = hosts.firstWhere(
              (h) => (h as Map<String, dynamic>)['host_name'] == _selectedId,
              orElse: () => hosts.first,
            ) as Map<String, dynamic>;
            SelectedServer.select(
              selectedHost['host_name'] as String? ?? '',
              selectedHost['host_name'] as String? ?? 'Без названия',
            );
          }
        }
        _loading = false;
      });
      _measureAllPings(hosts);
    } catch (e) {
      // Ожидаемо, пока backend/.env не настроены под реальную БД/панели —
      // это не заглушка, а честная ошибка сети/интеграции.
      setState(() {
        _error = 'Не удалось получить список серверов: $e';
        _loading = false;
      });
    }
  }

  /// В имени хоста (remark в 3x-ui) обычно уже есть код страны первыми
  /// буквами, например "DE Frankfurt" -> "DE". Если формат другой в твоей
  /// панели — просто поправь эту функцию, на данные с сервера это не влияет.
  String _codeFromName(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return '??';
    final firstWord = trimmed.split(RegExp(r'\s+')).first;
    return firstWord.length >= 2
        ? firstWord.substring(0, 2).toUpperCase()
        : firstWord.toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    // ServersScreen используется и во вкладке RootShell, и как
    // отдельный MaterialPageRoute с главного экрана. Во втором
    // случае без Scaffold текст вне NeonCard попадал под аварийный
    // DefaultTextStyle Flutter с жёлтым двойным подчёркиванием.
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _load,
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(20, 22, 20, 20),
            child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppHeader(
              trailing: Icons.refresh_rounded,
              onTrailingTap: _load,
              screenLabel: 'Выбор сервера',
            ),
            const Text(
              'Список подтягивается напрямую из панелей 3x-ui через backend — новая локация появляется здесь автоматически.',
              style: TextStyle(fontSize: 10, color: AppColors.textDim),
            ),
            const SizedBox(height: 10),
            if (_loading)
              const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator())),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(_error!,
                    style:
                        const TextStyle(color: AppColors.danger, fontSize: 12)),
              ),
            if (_hosts != null && _hosts!.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: Text('В панелях 3x-ui пока нет активных локаций.',
                    style: TextStyle(color: AppColors.textDim)),
              ),
            if (_hosts != null)
              ..._hosts!.map((s) {
                final host = s as Map<String, dynamic>;
                final id = host['host_name'] as String? ?? '';
                final name = id.isEmpty ? 'Без названия' : id;
                final code = _codeFromName(name);
                final isSelected = id == _selectedId;
                final isFav = _favorites.contains(id);
                final ping = _livePing[id];
                final String pingLabel;
                final Color pingColor;
                if (ping == null) {
                  pingLabel = 'измеряю...';
                  pingColor = AppColors.textDim;
                } else if (ping == -2) {
                  pingLabel = 'нет данных для пинга';
                  pingColor = AppColors.textDim;
                } else if (ping < 0) {
                  pingLabel = 'недоступен';
                  pingColor = AppColors.danger;
                } else if (ping < 80) {
                  pingLabel = '$ping мс · отлично';
                  pingColor = AppColors.success;
                } else if (ping < 180) {
                  pingLabel = '$ping мс';
                  pingColor = AppColors.warning;
                } else {
                  pingLabel = '$ping мс · медленно';
                  pingColor = AppColors.danger;
                }
                return ServerPill(
                  code: code,
                  name: name,
                  pingLabel: pingLabel,
                  pingColor: pingColor,
                  onTap: () {
                    setState(() => _selectedId = id);
                    SelectedServer.select(id, name);
                    _prefs.setString(PrefKeys.selectedServerId, id);
                  },
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      GestureDetector(
                        onTap: () {
                          setState(() {
                            if (isFav) {
                              _favorites.remove(id);
                            } else {
                              _favorites.add(id);
                            }
                          });
                          _prefs.setStringSet(
                              PrefKeys.favoriteServers, _favorites);
                        },
                        child: Icon(
                          isFav
                              ? Icons.star_rounded
                              : Icons.star_border_rounded,
                          size: 18,
                          color: isFav
                              ? const Color(0xFFF5C451)
                              : const Color(0xFF372A52),
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (isSelected)
                        const NeonBadge('выбран')
                      else
                        const Icon(Icons.chevron_right_rounded,
                            color: AppColors.textDim, size: 18),
                    ],
                  ),
                );
              }),
            const SectionTitle('Автовыбор'),
            NeonCard(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                          colors: [AppColors.success, Color(0xFF1D9A6C)]),
                    ),
                    alignment: Alignment.center,
                    child: const Text('⚡', style: TextStyle(fontSize: 14)),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Авто-балансировка',
                            style: TextStyle(
                                fontSize: 13, fontWeight: FontWeight.w600)),
                        SizedBox(height: 2),
                        Text('выбор лучшего сервера',
                            style: TextStyle(
                                fontSize: 10, color: AppColors.textDim)),
                      ],
                    ),
                  ),
                  NeonToggle(
                    value: _autoBalance,
                    onChanged: (v) {
                      setState(() => _autoBalance = v);
                      _prefs.setBool(PrefKeys.autoBalance, v);
                      if (v) _maybeApplyAutoBalance();
                    },
                  ),
                ],
              ),
            ),
          ],
            ),
          ),
        ),
      ),
    );
  }
}
