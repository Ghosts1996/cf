import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme.dart';
import '../widgets/neon.dart';
import '../services/api_client.dart';
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

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final keys = await _api.getKeys();
      setState(() {
        _keys = keys;
        _loading = false;
      });
    } on ApiException catch (e) {
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (e) {
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
    return RefreshIndicator(
      onRefresh: _load,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 22, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const AppHeader(trailing: Icons.menu_rounded, screenLabel: 'Мои ключи'),
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
