import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vpnonline_app/services/tunnel_service.dart';

/// Разбор `vless://`-ссылок в том виде, в каком их отдают панели: проверяем
/// не текст ссылки, а то, что из неё получается в конфиге ядра.
Map<String, dynamic> _outbound(String uri) {
  final config =
      jsonDecode(TunnelService.instance.buildConfigFromUri(uri, proxyOnly: true))
          as Map<String, dynamic>;
  return (config['outbounds'] as List).cast<Map<String, dynamic>>().first;
}

Map<String, dynamic>? _transport(String uri) =>
    _outbound(uri)['transport'] as Map<String, dynamic>?;

const _uuid = '11111111-1111-1111-1111-111111111111';

void main() {
  group('VLESS', () {
    test('UDP упаковывается в xudp — иначе сервер Xray его отбрасывает', () {
      expect(
        _outbound('vless://$_uuid@a.example.com:443?security=tls&type=tcp#X')[
            'packet_encoding'],
        'xudp',
      );
    });

    test('packetEncoding из ссылки имеет приоритет', () {
      expect(
        _outbound('vless://$_uuid@a.example.com:443'
            '?security=tls&type=tcp&packetEncoding=packetaddr#X')[
            'packet_encoding'],
        'packetaddr',
      );
    });
  });

  group('транспорт', () {
    test('ws: path и Host-заголовок', () {
      final t = _transport('vless://$_uuid@b.example.com:443'
          '?security=tls&type=ws&path=%2Fwsx&host=cdn.b.example.com#WS')!;
      expect(t['type'], 'ws');
      expect(t['path'], '/wsx');
      expect(t['headers'], {'Host': 'cdn.b.example.com'});
    });

    test('grpc: serviceName становится service_name', () {
      final t = _transport('vless://$_uuid@a.example.com:443'
          '?security=tls&type=grpc&serviceName=myservice#GRPC')!;
      expect(t['type'], 'grpc');
      expect(t['service_name'], 'myservice');
    });

    test('httpupgrade: Host уходит заголовком, как у Hiddify', () {
      final t = _transport('vless://$_uuid@d.example.com:443'
          '?security=tls&type=httpupgrade&path=%2Fhu&host=d.example.com#HU')!;
      expect(t['type'], 'httpupgrade');
      expect(t['headers'], {'Host': 'd.example.com'});
      expect(t['path'], '/hu');
    });

    test('ws: параметр ed выносится из пути в max_early_data', () {
      final t = _transport('vless://$_uuid@b.example.com:443'
          '?security=tls&type=ws&path=%2Fws%3Fed%3D2048#ED')!;
      expect(t['path'], '/ws');
      expect(t['max_early_data'], 2048);
      expect(t['early_data_header_name'], 'Sec-WebSocket-Protocol');
    });

    test('tcp + headerType=http — это HTTP-маскировка, а не голый TCP', () {
      final t = _transport('vless://$_uuid@c.example.com:80'
          '?type=tcp&headerType=http&host=c.example.com&path=%2Fp#HTTP')!;
      expect(t['type'], 'http');
      expect(t['host'], ['c.example.com']);
      expect(t['path'], '/p');
    });

    test('raw — так новый Xray называет голый TCP', () {
      final uri = 'vless://$_uuid@h.example.com:443'
          '?security=tls&type=raw&sni=h.example.com#RAW';
      expect(_transport(uri), isNull);
      // И главное: такой профиль не должен считаться неподдерживаемым.
      expect(
        () => TunnelService.instance.buildConfigFromUri(uri),
        returnsNormally,
      );
    });

    test('h2 — прежнее имя HTTP/2-транспорта', () {
      final t = _transport('vless://$_uuid@i.example.com:443'
          '?security=tls&type=h2&path=%2Fh2&host=i.example.com#H2')!;
      expect(t['type'], 'http');
    });

    test('tcp без маскировки идёт без блока transport', () {
      expect(
        _transport('vless://$_uuid@e.example.com:443?security=tls&type=tcp#TCP'),
        isNull,
      );
    });
  });

  group('TLS', () {
    test('reality собирается с публичным ключом и short id', () {
      final tls = _outbound('vless://$_uuid@g.example.com:443'
          '?security=reality&pbk=PUBKEY&sid=aa&flow=xtls-rprx-vision'
          '&type=tcp#FLOW')['tls'] as Map<String, dynamic>;
      final reality = tls['reality'] as Map<String, dynamic>;
      expect(reality['public_key'], 'PUBKEY');
      expect(reality['short_id'], 'aa');
      expect((tls['utls'] as Map)['fingerprint'], 'chrome');
    });

    test('alpn разбирается в список', () {
      final tls = _outbound('vless://$_uuid@f.example.com:443'
          '?security=tls&alpn=h2%2Chttp%2F1.1&type=tcp#ALPN')['tls']
          as Map<String, dynamic>;
      expect(tls['alpn'], ['h2', 'http/1.1']);
    });

    test('alpn для ws задаёт транспорт, а не ссылка', () {
      final tls = _outbound('vless://$_uuid@f.example.com:443'
          '?security=tls&type=ws&path=%2Fw&alpn=h3#WSALPN')['tls']
          as Map<String, dynamic>;
      expect(tls['alpn'], ['h2', 'http/1.1']);
    });

    test('uTLS без fp ставится только для reality', () {
      final plain = _outbound('vless://$_uuid@f.example.com:443'
          '?security=tls&type=tcp#PLAINTLS')['tls'] as Map<String, dynamic>;
      expect(plain.containsKey('utls'), isFalse);

      final withFp = _outbound('vless://$_uuid@f.example.com:443'
          '?security=tls&fp=firefox&type=tcp#FP')['tls']
          as Map<String, dynamic>;
      expect((withFp['utls'] as Map)['fingerprint'], 'firefox');
    });

    test('без security блока tls нет', () {
      expect(
        _outbound('vless://$_uuid@e.example.com:2052?type=ws&path=%2Fx#PLAIN')
            .containsKey('tls'),
        isFalse,
      );
    });

    test('reality без публичного ключа не парсится', () {
      expect(
        () => TunnelService.instance.buildConfigFromUri(
            'vless://$_uuid@x.example.com:443?security=reality&type=tcp#NOPBK'),
        throwsA(isA<TunnelException>()),
      );
    });
  });

  group('mux', () {
    test('по умолчанию выключен — сервер Xray его не понимает', () {
      final config = jsonDecode(TunnelService.instance.buildConfigFromUri(
        'vless://$_uuid@b.example.com:443?security=tls&type=ws&path=%2Fw#WS',
      )) as Map<String, dynamic>;
      final proxy =
          (config['outbounds'] as List).cast<Map<String, dynamic>>().first;
      expect(proxy.containsKey('multiplex'), isFalse);
    });

    test('не включается поверх flow: эта пара не работает', () {
      final outbound = jsonDecode(TunnelService.instance.buildConfigFromUri(
        'vless://$_uuid@g.example.com:443'
        '?security=reality&pbk=PUBKEY&flow=xtls-rprx-vision&type=tcp#FLOW',
        muxEnabled: true,
      )) as Map<String, dynamic>;
      final proxy = (outbound['outbounds'] as List)
          .cast<Map<String, dynamic>>()
          .first;
      expect(proxy.containsKey('multiplex'), isFalse);
    });

    test('включается, когда flow не задан', () {
      final config = jsonDecode(TunnelService.instance.buildConfigFromUri(
        'vless://$_uuid@b.example.com:443?security=tls&type=ws&path=%2Fw#WS',
        muxEnabled: true,
      )) as Map<String, dynamic>;
      final proxy =
          (config['outbounds'] as List).cast<Map<String, dynamic>>().first;
      expect((proxy['multiplex'] as Map)['enabled'], true);
    });
  });
}
