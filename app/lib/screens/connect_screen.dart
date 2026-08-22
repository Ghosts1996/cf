import 'dart:async';
import 'package:flutter/material.dart';
import '../theme.dart';
import '../widgets/neon.dart';
import '../services/api_client.dart';
import '../services/local_prefs.dart';
import '../services/tunnel_service.dart';
import '../state/selected_server.dart';
import 'plans_screen.dart';
import 'servers_screen.dart';

/// Экран подключения.
///
/// [ИСПРАВЛЕНО v4.2] Кнопка "Подключить" реально запускает/останавливает
/// VLESS-туннель через [TunnelService] (обёртка над flutter_vless), RX/TX/
/// таймер — живые значения из [VlessStatus].
///
/// [ИСПРАВЛЕНО] Раньше экран ожидал поля `active_in_panel` и
/// `subscription_url`, которых у реального `GET /user/keys` нет (см.
/// api.py/database.py в бэкапе, тот же контракт что и в keys_screen.dart).
/// Реальные поля: `expiry_date` (ISO-строка — активность = дата в
/// будущем) и `connection_string` (готовая ссылка для туннеля, а не
/// `subscription_url`). Поля `devices_used` тоже не существует — сервер
/// отдаёт только `devices_limit`, поэтому показываем один лимит без
/// "занято/всего".
///
/// [ИСПРАВЛЕНО] `measureBackendLatencyMs()` был методом придуманного
/// бэкенда и в реальном ApiClient отсутствует. Задержку до backend теперь
/// меряем на этом экране напрямую — секундомером вокруг лёгкого
/// авторизованного запроса `getHosts()` (это всё равно нужные данные,
/// отдельного /ping эндпоинта на сервере нет и придумывать его не стал).
///
/// [ИСПРАВЛЕНО — реальный баг со скриншота "нет данных о задержке"]
/// `TunnelService.connectedDelayMs()` в этой версии `tunnel_service.dart`
/// давно умеет реальный замер (TCP-connect до узла, на который поднят
/// туннель — см. докстринг метода), и `_measureLatency()` ниже честно его
/// вызывает и сохраняет результат в `_latencyMs`. Но геттер `_latencyLabel`
/// при подключённом туннеле игнорировал `_latencyMs` целиком и всегда
/// показывал захардкоженный текст "нет данных о задержке (ядро sing-box)" —
/// то есть измерение реально происходило и обновляло состояние, а на экран
/// результат никогда не попадал. Теперь `_latencyLabel` использует
/// измеренное значение и при подключённом туннеле тоже, а "нет данных"
/// показывается только тогда, когда TCP-подключение к узлу реально не
/// удалось (сервер не отвечает). Плюс раньше замер срабатывал только один
/// раз сразу после подключения/по кнопке "Тест скорости" — добавлен
/// `_latencyTimer`, который тихо обновляет цифру каждые 15 секунд, пока
/// туннель поднят (тот же паттерн, что и `_keyWatchTimer` ниже).
///
/// ВАЖНО: платформенная часть (App Group + Network Extension на iOS/macOS
/// через Xcode, xray.exe на Windows) не может быть настроена только правкой
/// .dart-файлов — см. app/NATIVE_SETUP.md.
class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key});
  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  final _api = ApiClient.instance;
  final _tunnel = TunnelService.instance;
  bool _connecting = false;
  bool _loadingKey = true;
  Map<String, dynamic>? _activeKey;
  String? _keyError;
  int? _latencyMs;
  // [НОВОЕ] Отдельный флаг "замер сейчас идёт" — без него, пока свежий
  // замер летит по сети, на экране на секунду-другую повисал бы предыдущий
  // (уже устаревший) результат, подписанный так, будто он свежий.
  bool _latencyChecking = false;
  // [НОВОЕ] Пока туннель поднят — тихо обновляем задержку раз в 15 секунд,
  // а не только один раз сразу после подключения (см. докстринг класса
  // выше про баг "нет данных о задержке").
  Timer? _latencyTimer;
  // [НОВОЕ] key_id ключа, на котором ПОДНЯТ туннель прямо сейчас (не
  // просто "лучший ключ на момент последней загрузки экрана" — эти два
  // значения могут разойтись, если срок истёк уже ПОСЛЕ подключения, пока
  // экран открыт). Нужен, чтобы понять, что именно нужно менять при
  // истечении: сравниваем не факт "изменился ли _activeKey", а именно
  // "истёк ли ключ, к которому подключён живой туннель".
  int? _connectedKeyId;
  Timer? _keyWatchTimer;
  // [НОВОЕ] Ключ, вставленный пользователем вручную на экране "Мои ключи"
  // (см. keys_screen.dart + services/local_prefs.dart::ManualKeyStore).
  // Если задан — используется ВМЕСТО ключа из личного кабинета (API),
  // см. _effectiveConnectionString ниже.
  String? _manualKey;
  // [НОВОЕ] Флаг "уже пробовали автоподключение в этой сессии экрана" —
  // без него автоподключение пыталось бы сработать при КАЖДОМ обновлении
  // _activeKey (а не только один раз при первом открытии экрана), включая
  // повторные вызовы _loadKeyState().
  bool _autoConnectTried = false;

  @override
  void initState() {
    super.initState();
    _tunnel.status.addListener(_onTunnelStatus);
    // [ИСПРАВЛЕНО v5] Раньше этот экран вообще не слушал SelectedServer —
    // ServerPill всегда показывал захардкоженные 'DE'/'Германия ·
    // Frankfurt', а выбор сервера на ServersScreen никак не влиял на то,
    // к какому серверу реально подключался туннель (см. tunnel_service.dart).
    SelectedServer.hostName.addListener(_onTunnelStatus);
    SelectedServer.displayName.addListener(_onTunnelStatus);
    _tunnel.connectedServerName.addListener(_onTunnelStatus);
    // [НОВОЕ] Реальный Kill Switch — если туннель отвалился неожиданно
    // (не по нажатию "Отключить") и идёт попытка восстановления, экран
    // должен это явно показать, а не молча остаться в "подключено".
    _tunnel.killSwitchBlocking.addListener(_onTunnelStatus);
    _manualKey = ManualKeyStore.instance.value;
    ManualKeyStore.instance.notifier.addListener(_onManualKeyChanged);
    ManualKeyStore.instance.ensureLoaded();
    _loadKeyState();
    // [НОВОЕ — по прямому требованию] Раньше список ключей перечитывался
    // ТОЛЬКО при открытии экрана и при нажатии "Подключить"/"Отключить" —
    // если приложение оставалось открытым дольше, чем оставшийся срок
    // текущего ключа, экран НЕ узнавал об истечении, пока пользователь сам
    // не дёрнет что-нибудь руками. Теперь раз в минуту тихо перепроверяем
    // список ключей и, если ключ, на котором реально поднят туннель,
    // истёк — переключаемся на следующий по сроку действия ключ (если он
    // есть) или отключаем туннель и показываем предложение купить ключ
    // (если активных ключей больше нет).
    _keyWatchTimer = Timer.periodic(const Duration(minutes: 1), (_) => _recheckKeyExpiry());
    // [НОВОЕ] См. докстринг класса — раньше задержка на подключённом
    // туннеле замерялась один раз и больше никогда не обновлялась сама.
    // Тикаем чаще, чем ключ, но не слишком часто — это TCP-connect до
    // реального VLESS-узла, незачем дёргать его каждую секунду.
    _latencyTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (_tunnel.isConnected && !_latencyChecking) _measureLatency();
    });
  }

  @override
  void dispose() {
    _tunnel.status.removeListener(_onTunnelStatus);
    SelectedServer.hostName.removeListener(_onTunnelStatus);
    SelectedServer.displayName.removeListener(_onTunnelStatus);
    _tunnel.connectedServerName.removeListener(_onTunnelStatus);
    _tunnel.killSwitchBlocking.removeListener(_onTunnelStatus);
    ManualKeyStore.instance.notifier.removeListener(_onManualKeyChanged);
    _keyWatchTimer?.cancel();
    _latencyTimer?.cancel();
    super.dispose();
  }

  void _onTunnelStatus() {
    if (mounted) setState(() {});
  }

  /// [НОВОЕ] Реагирует на сохранение/удаление ручного ключа на экране "Мои
  /// ключи" прямо во время работы приложения — не только при перезапуске.
  void _onManualKeyChanged() {
    if (!mounted) return;
    setState(() => _manualKey = ManualKeyStore.instance.value);
    if (_tunnel.isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Ключ обновлён. Переподключись, чтобы применить его.')),
      );
    }
  }

  /// [НОВОЕ] Ссылка на конфигурацию, которая реально пойдёт в
  /// TunnelService.connect(): ручной ключ, если он задан, иначе — ключ из
  /// личного кабинета (API). Ручной ключ приоритетнее: если пользователь
  /// сам вставил ссылку, значит он осознанно хочет использовать именно её
  /// (например, ту же самую подписку, что уже настроена и работает в
  /// другом VPN-клиенте), а не автоматически выбранный ключ из магазина.
  String? get _effectiveConnectionString {
    if (_manualKey != null && _manualKey!.trim().isNotEmpty) return _manualKey!.trim();
    return _activeKey?['connection_string'] as String?;
  }

  bool get _hasManualKey => _manualKey != null && _manualKey!.trim().isNotEmpty;

  /// Код локации для ServerPill — те же первые буквы имени, что и на
  /// ServersScreen (см. `_codeFromName` там), чтобы отображение не
  /// расходилось между экранами.
  String _codeFromName(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return '??';
    final firstWord = trimmed.split(RegExp(r'\s+')).first;
    return firstWord.length >= 2 ? firstWord.substring(0, 2).toUpperCase() : firstWord.toUpperCase();
  }

  bool _isActive(Map<String, dynamic> key) {
    final expiryStr = key['expiry_date'] as String?;
    final expiry = expiryStr != null ? DateTime.tryParse(expiryStr) : null;
    return expiry != null && expiry.isAfter(DateTime.now());
  }

  /// Срок действия ключа как [DateTime] (null, если поле отсутствует/битое) —
  /// общий парсинг для сортировки и для [_isActive].
  DateTime? _expiryOf(Map<String, dynamic> key) {
    final expiryStr = key['expiry_date'] as String?;
    return expiryStr != null ? DateTime.tryParse(expiryStr) : null;
  }

  Future<void> _loadKeyState() async {
    setState(() => _loadingKey = true);
    try {
      final keys = await _api.getKeys();
      final active = keys.cast<Map<String, dynamic>>().where(_isActive).toList();
      // [ИСПРАВЛЕНО] Раньше бралcя `active.first` — первый активный ключ в
      // том порядке, в котором его отдал бэкенд (обычно по дате покупки,
      // а не по остатку срока). Если у пользователя несколько ключей,
      // подключение могло уйти на тот, что истекает раньше остальных.
      // Теперь явно выбираем ключ с МАКСИМАЛЬНЫМ `expiry_date`, т.е. с
      // наибольшим оставшимся сроком аренды — как и должно быть.
      active.sort((a, b) {
        final ea = _expiryOf(a);
        final eb = _expiryOf(b);
        if (ea == null && eb == null) return 0;
        if (ea == null) return 1; // ключи без даты — в конец
        if (eb == null) return -1;
        return eb.compareTo(ea); // по убыванию: сначала дальше всех истекающий
      });
      setState(() {
        _activeKey = active.isNotEmpty ? active.first : null;
        _keyError = null;
        _loadingKey = false;
      });
      // [НОВОЕ] "Автоподключение при запуске" в SettingsScreen раньше
      // только сохраняло значение тумблера в LocalPrefs и больше ничего не
      // делало — сам туннель на старте экрана никогда не поднимался
      // автоматически, независимо от того, включён тумблер или нет. Теперь
      // при первой загрузке экрана (не при каждом фоновом обновлении, см.
      // _recheckKeyExpiry) — если тумблер включён, есть активный ключ и
      // туннель ещё не поднят — реально запускаем подключение.
      if (!_autoConnectTried) {
        _autoConnectTried = true;
        // [ИСПРАВЛЕНО] По умолчанию выключено — пользователь должен сам
        // включить автоподключение в Настройках, а не получать его "из
        // коробки" молча.
        final autoConnect = await LocalPrefs.instance.getBool(PrefKeys.autoConnect, fallback: false);
        if (autoConnect &&
            (_activeKey != null || _hasManualKey) &&
            !_tunnel.isConnected &&
            !_tunnel.isBusy) {
          unawaited(_toggleConnection());
        }
      }
    } catch (e) {
      setState(() {
        _keyError = 'Не удалось проверить статус ключа: $e';
        _loadingKey = false;
      });
    }
    _measureLatency();
  }

  /// [НОВОЕ] Тихая периодическая проверка (без спиннера на весь экран —
  /// вызывается фоново, пока пользователь может быть в середине другого
  /// действия). Три исхода:
  ///  1. Туннель не подключён — просто освежаем `_activeKey`, ничего
  ///     активно не переключаем (обычный поток при следующем нажатии
  ///     "Подключить" и так возьмёт актуальный лучший ключ).
  ///  2. Туннель подключён, ключ, на котором он поднят, всё ещё активен —
  ///     ничего не трогаем (не рвём рабочее соединение просто потому, что
  ///     "теоретически есть ключ подлиннее" — переключение по одному только
  ///     "стал длиннее" было бы лишним разрывом стабильного соединения).
  ///  3. Туннель подключён, а ключ, на котором он поднят, УЖЕ истёк —
  ///     переключаемся на следующий по сроку действия активный ключ, если
  ///     он есть, иначе отключаем туннель и предлагаем купить ключ.
  Future<void> _recheckKeyExpiry() async {
    if (!mounted) return;
    List<dynamic> keys;
    try {
      keys = await _api.getKeys();
    } catch (_) {
      return; // сетевой сбой — не рвём текущее соединение из-за временной недоступности API
    }
    if (!mounted) return;

    final active = keys.cast<Map<String, dynamic>>().where(_isActive).toList()
      ..sort((a, b) {
        final ea = _expiryOf(a);
        final eb = _expiryOf(b);
        if (ea == null && eb == null) return 0;
        if (ea == null) return 1;
        if (eb == null) return -1;
        return eb.compareTo(ea);
      });
    final newBest = active.isNotEmpty ? active.first : null;

    if (_hasManualKey && _tunnel.isConnected) {
      // Туннель поднят на ручном ключе — у него нет expiry_date из API,
      // поэтому логика "истёк/не истёк" сюда неприменима. Не трогаем
      // рабочее соединение.
      setState(() => _activeKey = newBest ?? _activeKey);
      return;
    }

    if (!_tunnel.isConnected || _connectedKeyId == null) {
      // Туннель не поднят прямо сейчас — просто освежаем список для UI.
      setState(() {
        _activeKey = newBest;
        _keyError = null;
      });
      return;
    }

    final connectedStillActive = keys
        .cast<Map<String, dynamic>>()
        .where((k) => (k['key_id'] as num?)?.toInt() == _connectedKeyId)
        .any(_isActive);
    if (connectedStillActive) {
      // Текущий рабочий ключ ещё не истёк — трогать активное соединение не нужно.
      setState(() => _activeKey = newBest ?? _activeKey);
      return;
    }

    // Ключ, на котором сейчас поднят туннель, истёк.
    if (newBest != null) {
      final connectionString = newBest['connection_string'] as String?;
      if (connectionString != null && connectionString.isNotEmpty) {
        setState(() {
          _activeKey = newBest;
          _connecting = true;
        });
        try {
          await _tunnel.disconnect();
          await _tunnel.connect(connectionString, preferredHostName: SelectedServer.hostName.value);
          _connectedKeyId = (newBest['key_id'] as num?)?.toInt();
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Срок действия предыдущего ключа истёк — переключились на следующий активный ключ')),
            );
          }
        } catch (e) {
          if (mounted) _showError('Ключ истёк, а переключиться на следующий не удалось: $e');
        } finally {
          if (mounted) setState(() => _connecting = false);
          _measureLatency();
        }
        return;
      }
    }

    // Активных ключей больше нет вообще — отключаем и честно предлагаем купить.
    _connectedKeyId = null;
    await _tunnel.disconnect();
    if (mounted) {
      setState(() {
        _activeKey = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Срок действия ключа истёк, других активных ключей нет — оформи новую подписку')),
      );
    }
  }

  Future<void> _measureLatency() async {
    // Если туннель уже поднят — меряем задержку ЧЕРЕЗ него (реальный сигнал
    // для пользователя). Иначе — грубая оценка "жив ли backend" секундомером
    // вокруг обычного авторизованного запроса (отдельного /ping эндпоинта
    // на реальном сервере нет).
    if (mounted) setState(() => _latencyChecking = true);
    try {
      if (_tunnel.isConnected) {
        final ms = await _tunnel.connectedDelayMs();
        if (mounted) setState(() => _latencyMs = ms);
        return;
      }
      final sw = Stopwatch()..start();
      try {
        await _api.getHosts();
        sw.stop();
        if (mounted) setState(() => _latencyMs = sw.elapsedMilliseconds);
      } catch (_) {
        sw.stop();
        if (mounted) setState(() => _latencyMs = null);
      }
    } finally {
      if (mounted) setState(() => _latencyChecking = false);
    }
  }

  Future<void> _toggleConnection() async {
    if ((_activeKey == null && !_hasManualKey) || _connecting || _tunnel.isBusy) return;
    final connectionString = _effectiveConnectionString;

    if (_tunnel.isConnected) {
      setState(() => _connecting = true);
      await _tunnel.disconnect();
      _connectedKeyId = null;
      setState(() => _connecting = false);
      _measureLatency();
      return;
    }

    if (connectionString == null || connectionString.isEmpty) {
      _showError('Для этого ключа пока нет ссылки на конфигурацию сервера — обратись в поддержку.');
      return;
    }

    setState(() => _connecting = true);
    try {
      // [ИСПРАВЛЕНО v5] Передаём сервер, выбранный на ServersScreen —
      // раньше этот параметр вообще не существовал, и туннель всегда
      // поднимался на первом сервере из подписки ключа, что бы
      // пользователь ни выбрал.
      await _tunnel.connect(connectionString, preferredHostName: SelectedServer.hostName.value);
      // [НОВОЕ] Запоминаем, к какому именно key_id реально подключился
      // туннель — нужно для _recheckKeyExpiry(), чтобы отличать "истёк
      // именно рабочий ключ" от "появился ещё более длинный ключ где-то
      // среди прочих" (см. докстринг метода выше).
      // Для ручного ключа key_id не существует (он не из API) — null, и
      // _recheckKeyExpiry() просто не трогает соединение на ручном ключе.
      _connectedKeyId = _hasManualKey ? null : (_activeKey?['key_id'] as num?)?.toInt();
      _measureLatency();
    } on TunnelException catch (e) {
      _showError(e.message, fallbackConnectionString: connectionString);
    } catch (e) {
      _showError('Не удалось подключиться: $e', fallbackConnectionString: connectionString);
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  void _showError(String message, {String? fallbackConnectionString}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: AppColors.danger,
        // [ИЗМЕНЕНО] Раньше здесь было быстрое переключение на сторонний
        // клиент тем же ключом. Вместо этого при ошибке
        // подключения ведём в системные настройки VPN на устройстве — это
        // помогает в самом частом реальном сценарии таких ошибок:
        // разрешение на VPN отозвано вручную или его удерживает другое
        // VPN-приложение, и без похода в системные настройки это не
        // починить программно.
        action: fallbackConnectionString == null
            ? null
            : SnackBarAction(
                label: 'Настройки VPN',
                textColor: AppColors.violet2,
                onPressed: () => _tunnel.openSystemVpnSettingsHint(),
              ),
        duration: fallbackConnectionString == null
            ? const Duration(seconds: 4)
            : const Duration(seconds: 8),
      ),
    );
  }

  String get _timerLabel {
    final seconds = _tunnel.status.value?.duration ?? 0;
    final d = Duration(seconds: seconds);
    final h = d.inHours.toString().padLeft(2, '0');
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  /// [ИСПРАВЛЕНО — реальный баг со скриншота "ПРИЁМ 0.0 MB / ОТДАЧА 0.0 MB"]
  /// Принимает именно НАКОПЛЕННЫЙ трафик сессии в байтах (см. вызов ниже —
  /// теперь `s?.downloadTotalBytes`/`s?.uploadTotalBytes`, а не
  /// `s?.download`/`s?.upload`).
  String _formatBytes(num? bytes) {
    if (bytes == null || bytes <= 0) return '0 MB';
    final mb = bytes / (1024 * 1024);
    if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
    return '${(mb / 1024).toStringAsFixed(2)} GB';
  }

  String get _latencyLabel {
    // [ИСПРАВЛЕНО — баг со скриншота] Раньше при подключённом туннеле тут
    // БЕЗУСЛОВНО возвращался захардкоженный текст "нет данных о задержке",
    // даже если `_measureLatency()` только что успешно получил реальное
    // значение в `_latencyMs` через TCP-connect до VLESS-узла
    // (`TunnelService.connectedDelayMs()`, см. tunnel_service.dart —
    // метод рабочий, просто его результат никогда не долетал до UI).
    // Теперь показываем то, что реально измерено, независимо от того,
    // подключены мы или нет — разница только в тексте на случай неудачи.
    if (_latencyChecking && _latencyMs == null) return 'проверка соединения…';
    if (_latencyMs == null) {
      // Замер завершился, но значения нет — либо TCP-подключение к узлу
      // не удалось (сервер не отвечает), либо это самый первый рендер до
      // первого запуска _measureLatency() из initState().
      return _tunnel.isConnected
          ? 'сервер не отвечает на проверку задержки'
          : 'проверка соединения…';
    }
    if (_latencyMs! < 80) return '$_latencyMs мс · отличный сигнал';
    if (_latencyMs! < 200) return '$_latencyMs мс · стабильно';
    return '$_latencyMs мс · медленно';
  }

  @override
  Widget build(BuildContext context) {
    final hasKey = _activeKey != null || _hasManualKey;
    final connected = _tunnel.isConnected;
    final s = _tunnel.status.value;
    // При ручном ключе `_activeKey` может отсутствовать: ключ есть, но
    // лимит устройств API не возвращал. Не разыменовываем nullable значение.
    final devicesLimit = (_activeKey?['devices_limit'] as num?)?.toInt();

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 20),
      child: Column(
        children: [
          const AppHeader(trailing: Icons.menu_rounded, screenLabel: 'Подключение'),
          if (_hasManualKey)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Row(
                children: [
                  const Icon(Icons.edit_note_rounded, size: 14, color: AppColors.violetGlow),
                  const SizedBox(width: 6),
                  const Text('Используется ключ, добавленный вручную',
                      style: TextStyle(fontSize: 11, color: AppColors.violetGlow, fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          const SizedBox(height: 18),
          if (_tunnel.killSwitchBlocking.value)
            Container(
              margin: const EdgeInsets.only(bottom: 14),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: AppColors.danger.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.danger.withValues(alpha: 0.4)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.warning_rounded, color: AppColors.danger, size: 18),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'Туннель неожиданно оборвался — восстанавливаю соединение. '
                      'Интернет сейчас идёт БЕЗ защиты VPN.',
                      style: TextStyle(fontSize: 11.5, color: AppColors.text, height: 1.4),
                    ),
                  ),
                ],
              ),
            ),
          _ConnectRing(
            connected: connected,
            hasKey: hasKey,
            loading: _loadingKey || _connecting,
            timerLabel: _timerLabel,
          ),
          const SizedBox(height: 28),
          if (_keyError != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(_keyError!, style: const TextStyle(color: AppColors.danger, fontSize: 12)),
            ),
          Builder(builder: (context) {
            // [ИСПРАВЛЕНО v5] Было захардкожено 'DE'/'Германия · Frankfurt'
            // независимо от того, что выбрано на ServersScreen. Теперь: имя
            // сервера, к которому туннель РЕАЛЬНО подключён сейчас (если
            // connect() переключился на резервный сервер подписки — это
            // покажет именно его), иначе — выбранный в ServersScreen,
            // иначе — "Автовыбор".
            final activeName = connected
                ? (_tunnel.connectedServerName.value ?? SelectedServer.displayName.value)
                : SelectedServer.displayName.value;
            final label = activeName ?? 'Автовыбор';
            return ServerPill(
              code: _codeFromName(label),
              name: label,
              pingLabel: _latencyLabel,
              pingColor: (!_latencyChecking && _latencyMs != null && _latencyMs! < 200)
                  ? AppColors.success
                  : AppColors.textDim,
              trailing: const Icon(Icons.chevron_right_rounded, color: AppColors.textDim, size: 18),
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ServersScreen())),
            );
          }),
          Row(
            children: [
              // [ИСПРАВЛЕНО — реальный баг со скриншота] `s?.download` /
              // `s?.upload` — это МГНОВЕННАЯ скорость (байт/сек с последнего
              // тика от sing-box, поле заполняется из stats.downlinkBps /
              // stats.uplinkBps в tunnel_service.dart::_applyTrafficStats).
              // В момент, когда по туннелю в конкретную секунду ничего не
              // передавалось (пользователь просто открыл экран и ничего не
              // грузит) — эта мгновенная скорость честно равна 0, и карточки
              // "Приём"/"Отдача" показывали "0.0 MB" ВСЮ сессию, даже спустя
              // несколько минут подключения, будто трафика не было вообще.
              // А подписаны эти карточки как накопленный трафик за сессию
              // ("Приём"/"Отдача", не "Скорость") — для этого в
              // TunnelStatus уже отдельно есть `downloadTotalBytes`/
              // `uploadTotalBytes`, которые как раз накапливаются и не
              // обнуляются между тиками (см. _applyTrafficStats/
              // _pollNativeTraffic). Раньше в UI они нигде не
              // использовались — теперь карточки читают именно их.
              StatMiniCard(label: 'Приём', value: _formatBytes(s?.downloadTotalBytes)),
              const SizedBox(width: 10),
              StatMiniCard(label: 'Отдача', value: _formatBytes(s?.uploadTotalBytes)),
              const SizedBox(width: 10),
              StatMiniCard(
                label: 'Устройств',
                value: devicesLimit != null ? '$devicesLimit' : '—',
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (!hasKey && !_loadingKey)
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () =>
                    Navigator.push(context, MaterialPageRoute(builder: (_) => const PlansScreen())),
                child: const Text('Оформить подписку'),
              ),
            )
          else
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () =>
                        Navigator.push(context, MaterialPageRoute(builder: (_) => const ServersScreen())),
                    child: const Text('Сменить сервер'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton(
                    onPressed: (_loadingKey || _connecting || _tunnel.isBusy) ? null : _toggleConnection,
                    style: connected
                        ? ElevatedButton.styleFrom(backgroundColor: const Color(0xFF241028))
                        : null,
                    child: (_connecting || _tunnel.isBusy)
                        ? const SizedBox(
                            width: 18, height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : Text(connected ? 'Отключить' : 'Подключить'),
                  ),
                ),
              ],
            ),
          const SizedBox(height: 14),
          PillButton(
            label: 'Тест скорости',
            icon: '⚡',
            onTap: () {
              if (!connected) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Тест скорости доступен после подключения к серверу')),
                );
                return;
              }
              _measureLatency();
            },
          ),
        ],
      ),
    );
  }
}

class _ConnectRing extends StatelessWidget {
  const _ConnectRing({
    required this.connected,
    required this.hasKey,
    required this.loading,
    required this.timerLabel,
  });

  final bool connected;
  final bool hasKey;
  final bool loading;
  final String timerLabel;

  @override
  Widget build(BuildContext context) {
    final ringColor = !hasKey ? AppColors.danger : (connected ? AppColors.violet2 : AppColors.border);
    return SizedBox(
      width: 200,
      height: 200,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Внешнее свечение — .globe-bg аналог за кольцом.
          Container(
            width: 220,
            height: 220,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [AppColors.violet2.withOpacity(connected ? 0.14 : 0.05), Colors.transparent],
              ),
            ),
          ),
          SizedBox(
            width: 200,
            height: 200,
            child: CustomPaint(
              painter: _RingPainter(
                progress: connected ? 0.86 : (hasKey ? 0.18 : 0.04),
                color: ringColor,
                glow: connected,
              ),
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (loading)
                const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.violetGlow),
                )
              else ...[
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: !hasKey ? AppColors.danger : (connected ? AppColors.success : AppColors.textDim),
                    boxShadow: connected
                        ? AppColors.glow(AppColors.success, blur: 8, alpha: 0.8)
                        : null,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  !hasKey ? 'НЕТ КЛЮЧА' : (connected ? 'ПОДКЛЮЧЕНО' : 'ОТКЛЮЧЕНО'),
                  style: orbitron(fontSize: 15, letterSpacing: 1),
                ),
                const SizedBox(height: 4),
                const Text('VLESS · Reality', style: TextStyle(color: AppColors.textDim, fontSize: 11)),
                if (connected) ...[
                  const SizedBox(height: 10),
                  Text(timerLabel,
                      style: orbitron(fontSize: 11, color: AppColors.violetGlow, fontWeight: FontWeight.w500)),
                ],
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// Кольцо с градиентной обводкой и свечением — воспроизводит SVG
/// .ring-fg с linearGradient(#a855f7 → #8b5cf6) и drop-shadow из макета.
class _RingPainter extends CustomPainter {
  _RingPainter({required this.progress, required this.color, required this.glow});
  final double progress; // 0..1 доля дуги
  final Color color;
  final bool glow;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.width / 2 - 6;
    final bgPaint = Paint()
      ..color = const Color(0xFF1C1330)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(center, radius, bgPaint);

    final rect = Rect.fromCircle(center: center, radius: radius);
    final gradient = SweepGradient(
      startAngle: -1.5708,
      endAngle: -1.5708 + 6.28319,
      colors: const [AppColors.violet2, AppColors.violet, AppColors.violet2],
      stops: const [0.0, 0.5, 1.0],
    );
    final fgPaint = Paint()
      ..shader = gradient.createShader(rect)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6
      ..strokeCap = StrokeCap.round;
    if (glow) {
      fgPaint.maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
    }
    final sweep = 6.28319 * progress;
    canvas.drawArc(rect, -1.5708, sweep, false, fgPaint);
  }

  @override
  bool shouldRepaint(covariant _RingPainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.color != color || oldDelegate.glow != glow;
}