import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vpnonline_app/services/tunnel_service.dart';

/// Выгружает конфиги во всех сочетаниях настроек, которые пользователь может
/// включить на экранах «Настройки» и «Безопасность». Файлы потом прогоняются
/// через настоящее ядро (`sing-box check`) — так видно, не собирает ли
/// какая-то комбинация конфиг, который ядро откажется принимать.
const _reality =
    'vless://66666666-7777-8888-9999-000000000000@de.example.com:443'
    '?security=reality&pbk=ZZZZYYYYXXXXWWWWVVVVUUUU0000111122223333444&sid=cd34'
    '&sni=www.microsoft.com&fp=chrome&flow=xtls-rprx-vision&type=tcp#DE';
const _ws = 'vless://66666666-7777-8888-9999-000000000000@nl.example.com:443'
    '?security=tls&sni=nl.example.com&type=ws&host=nl.example.com&path=%2Fws#NL';

void main() {
  test('матрица конфигов выгружается', () {
    final tunnel = TunnelService.instance;
    final dir = Directory('${Directory.systemTemp.path}/vpnonline-config-matrix');
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    dir.createSync(recursive: true);

    var written = 0;
    for (final proxyOnly in [false, true]) {
      for (final mux in [false, true]) {
        for (final dpi in [false, true]) {
          for (final ads in [false, true]) {
            for (final fakeIp in [false, true]) {
              for (final lan in [false, true]) {
                for (final ipv6 in [false, true]) {
                  final name = 'p${proxyOnly ? 1 : 0}m${mux ? 1 : 0}'
                      'd${dpi ? 1 : 0}a${ads ? 1 : 0}f${fakeIp ? 1 : 0}'
                      'l${lan ? 1 : 0}v${ipv6 ? 1 : 0}';
                  final raw = tunnel.buildConfigFromUri(
                    _reality,
                    proxyOnly: proxyOnly,
                    muxEnabled: mux,
                    dpiBypass: dpi,
                    blockAds: ads,
                    fakeIpDns: fakeIp,
                    bypassLan: lan,
                    ipv6Enabled: ipv6,
                    alternateUris: const [_ws],
                  );
                  // конфиг обязан быть валидным JSON ещё до ядра
                  jsonDecode(raw);
                  File('${dir.path}/$name.json').writeAsStringSync(raw);
                  written++;
                }
              }
            }
          }
        }
      }
    }

    // Отдельно — то, что зависит от полей, не покрытых перебором выше.
    final extras = <String, String>{
      'dns_custom': tunnel.buildConfigFromUri(_reality,
          dnsProvider: 'custom', customDns: '9.9.9.11'),
      'dns_custom_empty': tunnel.buildConfigFromUri(_reality,
          dnsProvider: 'custom', customDns: '   '),
      'dns_quad9': tunnel.buildConfigFromUri(_reality, dnsProvider: 'quad9'),
      'dns_unknown':
          tunnel.buildConfigFromUri(_reality, dnsProvider: 'какой-то'),
      'mux_h2mux': tunnel.buildConfigFromUri(_ws,
          muxEnabled: true, muxProtocol: 'h2mux'),
      'mux_yamux': tunnel.buildConfigFromUri(_ws,
          muxEnabled: true, muxProtocol: 'yamux'),
      'split_exclude': tunnel.buildConfigFromUri(_reality,
          selectedPackages: const ['com.example.bank'],
          extraExcludedPackages: const ['su.vpnonline.vpnonline_app']),
      'split_include': tunnel.buildConfigFromUri(_reality,
          splitTunnelMode: 'include',
          selectedPackages: const ['com.example.browser']),
      'dns_direct': tunnel.buildConfigFromUri(_reality, dnsProtection: false),
    };
    extras.forEach((name, raw) {
      jsonDecode(raw);
      File('${dir.path}/$name.json').writeAsStringSync(raw);
      written++;
    });

    // Конфиг строгого Kill Switch собирается отдельным методом и в матрицу
    // не попадает, а проверять его нужно ровно так же: он поднимается в
    // момент, когда у пользователя уже нет связи.
    final killSwitch = tunnel.buildBlockAllConfigForTest();
    jsonDecode(killSwitch);
    File('${dir.path}/kill_switch_block.json').writeAsStringSync(killSwitch);
    written++;

    // ignore: avoid_print
    print('matrix: ${dir.path} ($written конфигов)');
    expect(written, greaterThan(100));
  });
}
