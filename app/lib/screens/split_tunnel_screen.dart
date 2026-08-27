import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:installed_apps/installed_apps.dart';
import 'package:installed_apps/app_info.dart';
import '../theme.dart';
import '../widgets/neon.dart';
import '../services/local_prefs.dart';
import '../services/locale_service.dart';

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
  final Map<String, bool> _bypassed = {}; // packageName -> "отмечено в списке"
  // [НОВОЕ] Режим — см. PrefKeys.splitTunnelMode.
  // 'exclude' — отмеченные приложения идут В ОБХОД VPN (как раньше).
  // 'include' — ТОЛЬКО отмеченные приложения идут через VPN (режим Hiddify
  // "разрешить VPN только для выбранных приложений").
  String _mode = 'exclude';
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
    final savedMode = await _prefs.getString(PrefKeys.splitTunnelMode);
    // [ИСПРАВЛЕНО] Проверка `mounted` после `await` — без неё уход с
    // экрана до завершения чтения LocalPrefs приводил к падению
    // "setState() called after dispose()".
    if (!mounted) return;
    if (savedMode == 'include' || savedMode == 'exclude') _mode = savedMode!;
    if (!Platform.isAndroid) {
      setState(() {
        _bypassed.addAll(savedBypassed);
        _loading = false;
        _error = tr('Выбор приложений доступен только на Android — на этой платформе список системы недоступен.');
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
      // [ИСПРАВЛЕНО] Та же проверка после второго `await` — чтение списка
      // установленных приложений на слабом устройстве может занять
      // заметное время, и уход с экрана за это время — реальный сценарий.
      if (!mounted) return;
      apps.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      setState(() {
        _apps = apps;
        _bypassed.addAll(savedBypassed);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        // Частая причина — нет QUERY_ALL_PACKAGES в AndroidManifest.xml
        // (см. NATIVE_SETUP.md) или сборка сделана без прогона scaffold.
        _error = '${tr('Не удалось получить список приложений:')} $e';
      });
    }
  }

  /// [НОВОЕ] Переключение режима 'exclude' <-> 'include' — реально
  /// прокидывается в tunnel_service.dart::_buildSingBoxConfig
  /// (include_package/exclude_package на tun-инбаунде) при следующем
  /// подключении.
  Future<void> _setMode(String mode) async {
    if (mode == _mode) return;
    setState(() => _mode = mode);
    await _prefs.setString(PrefKeys.splitTunnelMode, mode);
  }

  @override
  Widget build(BuildContext context) {
    final isInclude = _mode == 'include';
    return AnimatedBuilder(
      animation: LocaleService.instance,
      builder: (context, _) => Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 22, 20, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AppHeader(trailing: Icons.arrow_back_rounded, onTrailingTap: () => Navigator.pop(context)),
                  Text(tr('Split-туннелирование'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  const SizedBox(height: 10),
                  // [НОВОЕ] Сегментированный переключатель режима — как
                  // "VPN для всех / выбранных приложений" в Hiddify.
                  Container(
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      color: AppColors.bgCard,
                      border: Border.all(color: AppColors.border),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: _ModeSegment(
                            label: tr('Обход выбранных'),
                            selected: !isInclude,
                            onTap: () => _setMode('exclude'),
                          ),
                        ),
                        Expanded(
                          child: _ModeSegment(
                            label: tr('Только выбранные'),
                            selected: isInclude,
                            onTap: () => _setMode('include'),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    isInclude
                        ? tr('Через VPN работают ТОЛЬКО отмеченные ниже приложения — остальные всегда напрямую.')
                        : tr('Отмеченные ниже приложения работают в обход VPN — например банк или локальные сервисы. '
                            'Список — реальные приложения с этого устройства.'),
                    style: const TextStyle(color: AppColors.textDim, fontSize: 11, height: 1.5),
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
      ),
    );
  }
}

/// [НОВОЕ] Один сегмент переключателя режима 'exclude'/'include' на
/// экране Split-туннелирования — простая кнопка-таб без внешних зависимостей.
class _ModeSegment extends StatelessWidget {
  const _ModeSegment({required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(vertical: 9),
        decoration: BoxDecoration(
          color: selected ? AppColors.violet2.withValues(alpha: 0.18) : Colors.transparent,
          borderRadius: BorderRadius.circular(9),
          border: selected ? Border.all(color: AppColors.violet2.withValues(alpha: 0.5)) : null,
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? AppColors.violetGlow : AppColors.textDim,
          ),
        ),
      ),
    );
  }
}