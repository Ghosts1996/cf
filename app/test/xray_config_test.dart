import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vpnonline_app/services/tunnel_service.dart';

void main() {
  Map<String, dynamic> build(List<String> links) =>
      jsonDecode(TunnelService.debugBuildXrayConfig(links))
          as Map<String, dynamic>;

  test('VLESS с шифрованием, gRPC и Reality — поля один в один из ссылки', () {
    final config = build([
      'vless://11111111-1111-1111-1111-111111111111@m.example.com:1505'
          '?type=grpc&serviceName=grpc&mode=multi&authority=cdn.example.com'
          '&security=reality&pbk=PUBKEY&sid=aa&spx=%2F&sni=iv.kommersant.ru'
          '&fp=qq&pqv=PQVKEY&flow=xtls-rprx-vision'
          '&encryption=mlkem768x25519plus.native.0rtt.KEY#Mobile',
    ]);
    final inbound = (config['inbounds'] as List).single as Map<String, dynamic>;
    expect(inbound['listen'], '127.0.0.1');
    expect(inbound['port'], 30000);
    expect(inbound['protocol'], 'socks');
    expect(inbound['settings'], {
      'auth': 'password',
      'accounts': [
        {'user': 'u', 'pass': 'p'},
      ],
      'udp': true,
      'ip': '127.0.0.1',
    });

    final outbound = (config['outbounds'] as List).first as Map<String, dynamic>;
    expect(outbound['tag'], 'out-0');
    expect(outbound['protocol'], 'vless');
    final server = outbound['settings']['vnext'][0] as Map<String, dynamic>;
    expect(server['address'], 'm.example.com');
    expect(server['port'], 1505);
    expect(server['users'], [
      {
        'id': '11111111-1111-1111-1111-111111111111',
        'encryption': 'mlkem768x25519plus.native.0rtt.KEY',
        'flow': 'xtls-rprx-vision',
      },
    ]);
    final stream = outbound['streamSettings'] as Map<String, dynamic>;
    expect(stream['network'], 'grpc');
    expect(stream['security'], 'reality');
    expect(stream['grpcSettings'], {
      'serviceName': 'grpc',
      'multiMode': true,
      'authority': 'cdn.example.com',
    });
    expect(stream['realitySettings'], {
      'serverName': 'iv.kommersant.ru',
      'fingerprint': 'qq',
      'publicKey': 'PUBKEY',
      'shortId': 'aa',
      'spiderX': '/',
      'mldsa65Verify': 'PQVKEY',
    });
    expect(config['routing'], {
      'rules': [
        {
          'type': 'field',
          'inboundTag': ['in-0'],
          'outboundTag': 'out-0',
        },
      ],
    });
  });

  test('без encryption в ссылке — none, как требует Xray', () {
    final config = build([
      'vless://11111111-1111-1111-1111-111111111111@de.example.com:443'
          '?type=tcp&security=reality&pbk=PUBKEY&sni=yahoo.com#DE',
    ]);
    final user = (config['outbounds'] as List).first['settings']['vnext'][0]
        ['users'][0] as Map<String, dynamic>;
    expect(user['encryption'], 'none');
    expect(user.containsKey('flow'), isFalse);
    final reality = (config['outbounds'] as List).first['streamSettings']
        ['realitySettings'] as Map<String, dynamic>;
    expect(reality['fingerprint'], 'chrome', reason: 'как и в sing-box');
  });

  test('XHTTP с extra и trojan по WebSocket с TLS', () {
    final config = build([
      'vless://11111111-1111-1111-1111-111111111111@x.example.com:443'
          '?type=xhttp&path=%2Fup&host=cdn.example.com&mode=packet-up'
          '&extra=%7B%22xPaddingBytes%22%3A%22100-1000%22%7D'
          '&security=tls&sni=cdn.example.com&alpn=h2%2Chttp%2F1.1&fp=chrome#X',
      'trojan://secret@t.example.com:443?type=ws&path=%2Fws&host=t.example.com'
          '&security=tls&sni=t.example.com#T',
    ]);
    final outbounds = (config['outbounds'] as List).cast<Map<String, dynamic>>();
    expect(outbounds.length, 3, reason: 'два сервера и blackhole');
    final xhttp = outbounds[0]['streamSettings'] as Map<String, dynamic>;
    expect(xhttp['xhttpSettings'], {
      'path': '/up',
      'host': 'cdn.example.com',
      'mode': 'packet-up',
      'extra': {'xPaddingBytes': '100-1000'},
    });
    expect(xhttp['tlsSettings'], {
      'serverName': 'cdn.example.com',
      'fingerprint': 'chrome',
      'alpn': ['h2', 'http/1.1'],
    });
    final trojan = outbounds[1];
    expect(trojan['protocol'], 'trojan');
    expect(trojan['settings'], {
      'servers': [
        {'address': 't.example.com', 'port': 443, 'password': 'secret'},
      ],
    });
    expect(trojan['streamSettings']['wsSettings'],
        {'path': '/ws', 'host': 't.example.com'});
    expect((config['inbounds'] as List).map((i) => i['port']), [30000, 30001]);
  });
}
