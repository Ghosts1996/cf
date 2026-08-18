import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:installed_apps/installed_apps.dart';
import 'package:installed_apps/app_info.dart';
import '../theme.dart';
import '../widgets/neon.dart';
import '../services/local_prefs.dart';

/// Split-туннелирование — сведено по SCREEN 8 макета (.app-toggle-row).
///
/// [ИСПРАВЛЕНО] Раньше здесь был фиксированный демо-список из 5 названий
/// ('Банк Онлайн', 'Карты', ...) — не имел отношения к реальному
/// устройству. Теперь список реально читается через пакет `installed_apps`
/// (Android-only, требует QUERY_ALL_PACKAGES — см. NATIVE_SETUP.md).
///
/// [ИСПРАВЛЕНО] Раньше выбор здесь сохранялся в LocalPrefs, но реального
/// эффекта на трафик не было — TunnelService его не читал. Теперь при
/// каждом `connect()` (см. tunnel_service.dart) сохранённая карта
/// пакетов читается и передаётся в конфиг sing-box как `exclude_package`
/// на tun-инбаунде — приложения, отмеченные здесь как "в обход VPN",
/// реально не заворачиваются в туннель (Android VpnService на уровне
/// ядра sing-box). Чтобы применить изменение к уже запущенному туннелю,
/// нужно переподключиться — на лету (без разрыва сессии) список не
/// обновляется.
///
/// [ИСПРАВЛЕНО] Выбор ("_bypassed") раньше был обычным `Map` полем State —
/// сбрасывался при уходе с экрана/перезапуске приложения (то же семейство
/// багов, что и остальные тумблеры — см. services/local_prefs.dart).
/// Теперь читается/пишется в LocalPrefs при каждом переключении.
class SplitTunnelScreen extends StatefulWidget {
  const SplitTunnelScreen({super.key});
  @override
  State<SplitTunnelScreen> createState() => _SplitTunnelScreenState();
}

class _SplitTunnelScreenState extends State<SplitTunnelScreen> {
  final _prefs = LocalPrefs.instance;
  List<AppInfo> _apps = [];
  final Map<String, bool> _bypassed = {}; // packageName -> "идёт в обход VPN"
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // [НОВОЕ] Восстанавливаем ранее сохранённый выбор ДО показа списка —
    // иначе первая отрисовка на секунду показала бы все тумблеры выключенными
    // (значения по умолчанию), а потом "дёрнулась" бы после чтения из
    // хранилища. Загружаем оба источника параллельно и объединяем один раз.
    final savedBypassed = await _prefs.getBoolMap(PrefKeys.splitTunnelBypass);
    if (!Platform.isAndroid) {
      setState(() {
        _bypassed.addAll(savedBypassed);
        _loading = false;
        _error = 'Выбор приложений доступен только на Android — на этой платформе список системы недоступен.';
      });
      return;
    }
    try {
      // [ИСПРАВЛЕНО — критично] У пакета installed_apps ^2.0.0 параметр
      // withIcon по умолчанию false (проверено по официальному README
      // пакета на pub.dev) — без него app.icon всегда null, и UI ниже
      // молча уходил в ветку с эмодзи-заглушкой 📱 для АБСОЛЮТНО ВСЕХ
      // приложений, на любом телефоне. Это не было связано с конкретным
      // устройством — баг был в самом вызове API, иконки не запрашивались
      // вообще.
      final apps = await InstalledApps.getInstalledApps(
        excludeSystemApps: true,
        excludeNonLaunchableApps: true,
        withIcon: true,
      );
      apps.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      setState(() {
        _apps = apps;
        _bypassed.addAll(savedBypassed);
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _loading = false;
        // Частая причина — нет QUERY_ALL_PACKAGES в AndroidManifest.xml
        // (см. NATIVE_SETUP.md) или сборка сделана без прогона scaffold.
        _error = 'Не удалось получить список приложений: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 22, 20, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AppHeader(trailing: Icons.arrow_back_rounded, onTrailingTap: () => Navigator.pop(context)),
                  const Text('Split-туннелирование', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  const SizedBox(height: 8),
                  const Text(
                    'Выбери, какие приложения работают в обход VPN — например банк или локальные сервисы. '
                    'Список — реальные приложения с этого устройства.',
                    style: TextStyle(color: AppColors.textDim, fontSize: 11, height: 1.5),
                  ),
                  const SizedBox(height: 10),
                ],
              ),
            ),
            if (_loading) const Expanded(child: Center(child: CircularProgressIndicator())),
            if (_error != null)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Center(
                    child: Text(_error!, style: const TextStyle(color: AppColors.danger, fontSize: 12), textAlign: TextAlign.center),
                  ),
                ),
              ),
            if (!_loading && _error == null)
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                  itemCount: _apps.length,
                  itemBuilder: (context, i) {
                    final app = _apps[i];
                    final bypassed = _bypassed[app.packageName] ?? false;
                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                      decoration: BoxDecoration(
                        color: AppColors.bgCard,
                        border: Border.all(color: AppColors.border),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 30,
                            height: 30,
                            decoration: BoxDecoration(color: const Color(0xFF1C1330), borderRadius: BorderRadius.circular(9)),
                            alignment: Alignment.center,
                            clipBehavior: Clip.antiAlias,
                            child: app.icon is Uint8List && (app.icon as Uint8List).isNotEmpty
                                ? Image.memory(app.icon as Uint8List, width: 30, height: 30, fit: BoxFit.cover)
                                : const Text('📱', style: TextStyle(fontSize: 14)),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(app.name, style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis),
                          ),
                          NeonToggle(
                            value: bypassed,
                            onChanged: (v) {
                              setState(() => _bypassed[app.packageName] = v);
                              _prefs.setBoolMap(PrefKeys.splitTunnelBypass, _bypassed);
                            },
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}
