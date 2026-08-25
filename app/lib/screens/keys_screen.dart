import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme.dart';
import '../widgets/neon.dart';
import '../services/api_client.dart';
import '../services/local_prefs.dart';
import '../services/tunnel_service.dart';
import 'plans_screen.dart';

/// Экран «Мои ключи».
///
/// [ИСПРАВЛЕНО — по факту чтения реального кода, не по виду]
/// Предыдущая версия (v4-ci) ожидала поля `id`, `vless_uri`, `devices_used`,
/// `group_id` и группировала строки как "одна покупка = несколько строк по
/// локациям". Ничего из этого не совпадает с реальным API:
/// `GET /user/keys` (см. api.py/database.py в бэкапе) отдаёт список
/// объектов `vpn_keys` как есть — один купленный ключ = ОДНА строка с
/// полями `key_id`, `host_name` (после покупки всегда `"GLOBAL"` — единая
/// подписка на все локации живёт на уровне ссылки-подписки, не отдельных
/// строк в БД), `key_email`, `expiry_date`, `devices_limit`,
/// `connection_string` (добавляется самим API-роутом поверх данных БД).
/// Группировка по `group_id` была лишней сложностью под несуществующие
/// данные — убрана.
class KeysScreen extends StatefulWidget {
  const KeysScreen({super.key});
  @override
  State<KeysScreen> createState() => _KeysScreenState();
}

class _KeysScreenState extends State<KeysScreen> {
  final _api = ApiClient.instance;
  List<dynamic>? _keys;
  String? _error;
  bool _loading = true;

  // [НОВОЕ] Поле "свой ключ" — по прямому требованию: возможность вставить
  // ссылку на подписку/vless:// вручную, в обход ключей из личного
  // кабинета.
  // Хранится через ManualKeyStore (services/local_prefs.dart) — оттуда её
  // читает ConnectScreen при подключении, см. connect_screen.dart.
  final _manualKeyController = TextEditingController();
  bool _manualKeySaving = false;
  // [НОВОЕ] Флаг загрузки для кнопки "Проверить ключ" — см. _validateManualKey.
  bool _manualKeyValidating = false;

  @override
  void initState() {
    super.initState();
    _load();
    _loadManualKey();
  }

  Future<void> _loadManualKey() async {
    await ManualKeyStore.instance.ensureLoaded();
    if (mounted) {
      _manualKeyController.text = ManualKeyStore.instance.value ?? '';
    }
  }

  @override
  void dispose() {
    _manualKeyController.dispose();
    super.dispose();
  }

  Future<void> _saveManualKey() async {
    final text = _manualKeyController.text.trim();
    if (text.isNotEmpty && !text.startsWith('vless://') && !text.startsWith('http://') && !text.startsWith('https://')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Похоже на неверную ссылку — жду vless://... или http(s)://ссылку на подписку'),
          backgroundColor: AppColors.danger,
        ),
      );
      return;
    }
    setState(() => _manualKeySaving = true);
    await ManualKeyStore.instance.set(text);
    if (mounted) {
      setState(() => _manualKeySaving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(text.isEmpty ? 'Ручной ключ удалён' : 'Ключ сохранён — теперь подключение пойдёт по нему')),
      );
    }
  }

  /// [НОВОЕ] "Проверить ключ" — реально скачивает и расшифровывает
  /// подписку/ссылку из поля (тем же кодом, что и подключение — см.
  /// TunnelService.checkSubscription()) и честно показывает, сколько
  /// рабочих серверов в ней нашлось, БЕЗ подъёма самого туннеля. Нужно
  /// именно для того, чтобы проверять формат ссылок вроде
  /// `https://.../sub/<uuid>` до того, как жать "Подключить" на главном
  /// экране — если тут ключ не распознаётся, туннель тоже не поднимется,
  /// и это будет видно сразу, с понятным списком причин.
  Future<void> _validateManualKey() async {
    final text = _manualKeyController.text.trim();
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Сначала вставь vless://-ссылку или ссылку на подписку')),
      );
      return;
    }
    setState(() => _manualKeyValidating = true);
    final result = await TunnelService.instance.checkSubscription(text);
    if (!mounted) return;
    setState(() => _manualKeyValidating = false);
    if (result.ok) {
      showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: AppColors.bgCard,
          title: Text('Найдено серверов: ${result.serverCount}'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(
              shrinkWrap: true,
              children: result.serverNames
                  .map((name) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          children: [
                            const Icon(Icons.check_circle_rounded, size: 16, color: AppColors.success),
                            const SizedBox(width: 8),
                            Expanded(child: Text(name, style: const TextStyle(fontSize: 13))),
                          ],
                        ),
                      ))
                  .toList(),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Ок')),
          ],
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result.error ?? 'Ключ не распознан'), backgroundColor: AppColors.danger),
      );
    }
  }

  Future<void> _clearManualKey() async {
    _manualKeyController.clear();
    await ManualKeyStore.instance.clear();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Ручной ключ удалён — снова используются ключи из личного кабинета')),
      );
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final keys = await _api.getKeys();
      // [ИСПРАВЛЕНО] Без проверки `mounted` после `await` уход с экрана
      // (например, назад в меню) до ответа сервера приводил к падению
      // `setState() called after dispose()` — особенно вероятно именно на
      // медленной мобильной сети, где запрос идёт дольше обычного.
      if (!mounted) return;
      setState(() {
        _keys = keys;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Не удалось загрузить ключи: $e';
        _loading = false;
      });
    }
  }

  void _buyNew() {
    Navigator.push(context, MaterialPageRoute(builder: (_) => const PlansScreen()));
  }

  void _extend(Map<String, dynamic> key) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => PlansScreen(extendKeyId: (key['key_id'] as num).toInt())),
    ).then((_) => _load()); // обновить список после возможного продления
  }

  Future<void> _addDevice(Map<String, dynamic> key) async {
    try {
      final newLimit = await _api.upgradeKeyDevices((key['key_id'] as num).toInt());
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Лимит устройств увеличен до $newLimit')),
        );
        _load();
      }
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message), backgroundColor: AppColors.danger),
        );
      }
    }
  }

  void _copyLink(String link) {
    Clipboard.setData(ClipboardData(text: link));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Ссылка скопирована')),
    );
  }

  @override
  Widget build(BuildContext context) {
    // [ИСПРАВЛЕНО] KeysScreen встроен во вкладку RootShell (там уже есть
    // общий Scaffold), но также открывается отдельным MaterialPageRoute —
    // из MenuScreen, BalanceScreen и из самого себя (_buyNew/_extend ->
    // PlansScreen и обратно). Во втором случае без собственного Scaffold
    // текст вне NeonCard попадал под аварийный DefaultTextStyle Flutter с
    // жёлтым двойным подчёркиванием (нет Material-предка). Вложенный
    // Scaffold внутри Scaffold безопасен — тот же паттерн уже используется
    // в servers_screen.dart, который тоже одновременно вкладка и маршрут.
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
            const AppHeader(trailing: Icons.menu_rounded, screenLabel: 'Мои ключи'),
            const SizedBox(height: 16),
            _ManualKeyCard(
              controller: _manualKeyController,
              saving: _manualKeySaving,
              validating: _manualKeyValidating,
              onSave: _saveManualKey,
              onClear: _clearManualKey,
              onValidate: _validateManualKey,
            ),
            const SizedBox(height: 16),
            if (_loading) const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 20),
                child: Column(
                  children: [
                    const Icon(Icons.cloud_off_rounded, color: AppColors.textDim, size: 36),
                    const SizedBox(height: 12),
                    Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.danger, fontSize: 13)),
                    const SizedBox(height: 12),
                    OutlinedButton(onPressed: _load, child: const Text('Повторить')),
                  ],
                ),
              ),
            if (_keys != null && _keys!.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 30),
                child: Column(
                  children: [
                    const Icon(Icons.vpn_key_off_rounded, color: AppColors.textDim, size: 36),
                    const SizedBox(height: 12),
                    const Text('У тебя пока нет ключей', style: TextStyle(color: AppColors.textDim)),
                    const SizedBox(height: 12),
                    ElevatedButton(onPressed: _buyNew, child: const Text('Оформить подписку')),
                  ],
                ),
              ),
            if (_keys != null)
              for (final raw in _keys!) ...[
                _KeyCard(
                  data: raw as Map<String, dynamic>,
                  onCopy: _copyLink,
                  onExtend: () => _extend(raw),
                  onAddDevice: () => _addDevice(raw),
                ),
                const SizedBox(height: 12),
              ],
            if (_keys != null && _keys!.isNotEmpty)
              PillButton(label: 'Купить новый ключ', dashed: true, onTap: _buyNew),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _KeyCard extends StatelessWidget {
  const _KeyCard({required this.data, required this.onCopy, required this.onExtend, required this.onAddDevice});

  final Map<String, dynamic> data;
  final void Function(String link) onCopy;
  final VoidCallback onExtend;
  final VoidCallback onAddDevice;

  @override
  Widget build(BuildContext context) {
    final expiryStr = data['expiry_date'] as String?;
    final expiry = expiryStr != null ? DateTime.tryParse(expiryStr) : null;
    final daysLeft = expiry?.difference(DateTime.now()).inDays.clamp(0, 100000);
    final active = expiry != null && expiry.isAfter(DateTime.now());
    final devicesLimit = (data['devices_limit'] as num?)?.toInt() ?? 3;
    final link = data['connection_string'] as String?;

    return NeonCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Ключ #${data['key_id']}', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
              NeonBadge(active ? 'активен' : 'истёк', color: active ? AppColors.success : AppColors.danger),
            ],
          ),
          const SizedBox(height: 10),
          if (link != null && link.isNotEmpty)
            GestureDetector(
              onTap: () => onCopy(link),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                decoration: BoxDecoration(
                  color: const Color(0xFF0A0614),
                  border: Border.all(color: AppColors.border),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.link_rounded, size: 14, color: AppColors.textDim),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(link, maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11, color: AppColors.textDim)),
                    ),
                    const Text('Копировать', style: TextStyle(fontSize: 11, color: AppColors.violetGlow, fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            )
          else
            const Text('Ссылка временно недоступна — панель могла быть недоступна при запросе',
                style: TextStyle(fontSize: 11, color: AppColors.textDim)),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Лимит устройств', style: TextStyle(fontSize: 12, color: AppColors.textDim)),
              Row(children: [
                Text('$devicesLimit / 4', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                if (devicesLimit < 4) ...[
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: onAddDevice,
                    child: const Text('+ докупить (50 ₽)',
                        style: TextStyle(fontSize: 11, color: AppColors.violetGlow, fontWeight: FontWeight.w600)),
                  ),
                ],
              ]),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Срок действия', style: TextStyle(fontSize: 12, color: AppColors.textDim)),
              Text(daysLeft != null ? 'Осталось $daysLeft дн.' : '—',
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: onExtend,
              icon: const Icon(Icons.refresh_rounded, size: 16),
              label: const Text('Продлить ключ'),
            ),
          ),
        ],
      ),
    );
  }
}

/// [НОВОЕ] Карточка "свой ключ" на экране "Мои ключи" — по прямому
/// требованию: пользователь может вставить готовую ссылку (vless:// или
/// http(s)-подписку) вручную, вместо/поверх ключей из личного кабинета.
/// Полезно, например, когда есть ключ, который уже работает в другом
/// VPN-клиенте, и его нужно использовать именно так, как есть.
class _ManualKeyCard extends StatelessWidget {
  const _ManualKeyCard({
    required this.controller,
    required this.saving,
    required this.validating,
    required this.onSave,
    required this.onClear,
    required this.onValidate,
  });

  final TextEditingController controller;
  final bool saving;
  final bool validating;
  final VoidCallback onSave;
  final VoidCallback onClear;
  final VoidCallback onValidate;

  @override
  Widget build(BuildContext context) {
    return NeonCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: const [
              Icon(Icons.edit_note_rounded, size: 16, color: AppColors.violetGlow),
              SizedBox(width: 8),
              Text('Свой ключ (вручную)', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            'Вставь vless://-ссылку или ссылку на подписку — приложение подключится '
            'именно по ней, в приоритете перед ключами из личного кабинета. Оставь поле '
            'пустым и сохрани, чтобы вернуться к ключам из личного кабинета.',
            style: TextStyle(fontSize: 11.5, color: AppColors.textDim, height: 1.4),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: controller,
            maxLines: 3,
            minLines: 1,
            style: const TextStyle(fontSize: 12, color: AppColors.text),
            decoration: InputDecoration(
              hintText: 'vless://... или https://.../sub/...',
              hintStyle: const TextStyle(fontSize: 12, color: AppColors.textDim),
              filled: true,
              fillColor: const Color(0xFF0A0614),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: AppColors.border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: AppColors.border),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: AppColors.violetGlow),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  onPressed: saving ? null : onSave,
                  child: saving
                      ? const SizedBox(
                          height: 16,
                          width: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Сохранить'),
                ),
              ),
              const SizedBox(width: 10),
              OutlinedButton(onPressed: saving ? null : onClear, child: const Text('Удалить')),
            ],
          ),
          const SizedBox(height: 10),
          // [НОВОЕ] Проверяет ссылку прямо сейчас — реально скачивает и
          // расшифровывает подписку (тот же код, что и подключение, см.
          // TunnelService.checkSubscription) и показывает список найденных
          // серверов, БЕЗ подъёма туннеля. Полезно именно для диагностики
          // ссылок вида https://.../sub/<uuid> до нажатия "Подключить".
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: validating ? null : onValidate,
              icon: validating
                  ? const SizedBox(
                      height: 14,
                      width: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.fact_check_rounded, size: 16),
              label: const Text('Проверить ключ'),
            ),
          ),
        ],
      ),
    );
  }
}