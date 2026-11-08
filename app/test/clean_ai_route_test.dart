import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:vpnonline_app/services/tunnel_service.dart';

/// Google/Gemini/нейросети должны уходить на НАШ сервер (vpnonline_own=1, у него
/// WARP — чистый выход), даже когда активна чужая нода: иначе Google показывает
/// капчу «подозрительный трафик».
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final tunnel = TunnelService.instance;

  // Чужая нода (без метки) и наш сервер (с vpnonline_own=1).
  String uri(String host, String name, {bool own = false}) =>
      'vless://11111111-2222-3333-4444-555555555555@$host:443'
      '?security=reality&pbk=ZZZZYYYYXXXXWWWWVVVVUUUU0000111122223333444&sid=cd34'
      '&sni=www.microsoft.com&fp=chrome&flow=xtls-rprx-vision&type=tcp'
      '${own ? '&vpnonline_own=1' : ''}#$name';

  Map<String, dynamic> build(String primary, List<String> alts,
      {bool dpiBypass = false}) {
    final raw = tunnel.buildConfigFromUri(primary,
        alternateUris: alts, dpiBypass: dpiBypass);
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  List<Map> outs(Map<String, dynamic> c) =>
      (c['outbounds'] as List).cast<Map>();
  List<Map> rules(Map<String, dynamic> c) =>
      ((c['route'] as Map)['rules'] as List).cast<Map>();

  test('активна чужая нода, но среди локаций есть свой сервер — Google уходит '
      'на свой (clean-ai) через все свои серверы', () {
    final c = build(
      uri('ex1.example.com', 'Чужая'), // активная — чужая
      [uri('own.example.com', 'Германия', own: true), uri('ex2.example.com', 'США')],
    );
    final clean = outs(c).firstWhere((o) => o['tag'] == 'clean-ai', orElse: () => {});
    expect(clean.isNotEmpty, isTrue, reason: 'нет группы clean-ai');
    expect(clean['type'], 'urltest');
    // в группе только наш сервер (out-1), чужие — нет
    expect(clean['outbounds'], ['out-1']);
    final gRule = rules(c).firstWhere(
        (r) => r['outbound'] == 'clean-ai', orElse: () => {});
    expect(gRule.isNotEmpty, isTrue, reason: 'нет правила на clean-ai');
    expect((gRule['domain_suffix'] as List).contains('google.com'), isTrue);
    expect((gRule['domain_suffix'] as List).contains('chatgpt.com'), isTrue);
  });

  test('своих серверов в сессии нет — группу и правило не добавляем', () {
    final c = build(uri('ex1.example.com', 'Чужая'),
        [uri('ex2.example.com', 'США'), uri('ex3.example.com', 'Чехия')]);
    expect(outs(c).any((o) => o['tag'] == 'clean-ai'), isFalse);
    expect(rules(c).any((r) => r['outbound'] == 'clean-ai'), isFalse);
  });

  test('правило clean-ai стоит раньше широкого tls_fragment (иначе Google '
      'ушёл бы в выбранную локацию)', () {
    final c = build(
      uri('ex1.example.com', 'Чужая'),
      [uri('own.example.com', 'Германия', own: true)],
      dpiBypass: true, // добавляет правило tls_fragment на весь TCP
    );
    final rs = rules(c);
    final cleanAt = rs.indexWhere((r) => r['outbound'] == 'clean-ai');
    final fragAt = rs.indexWhere((r) => r['tls_fragment'] == true);
    expect(cleanAt, greaterThanOrEqualTo(0));
    expect(fragAt, greaterThanOrEqualTo(0));
    expect(cleanAt < fragAt, isTrue, reason: 'clean-ai должно идти раньше tls_fragment');
  });

  test('все локации — свои: Google всё равно на clean-ai из всех своих', () {
    final c = build(
      uri('own1.example.com', 'Германия', own: true),
      [uri('own2.example.com', 'Чехия', own: true)],
    );
    final clean = outs(c).firstWhere((o) => o['tag'] == 'clean-ai', orElse: () => {});
    expect(clean.isNotEmpty, isTrue);
    expect(clean['outbounds'], ['out-0', 'out-1']);
  });
}
