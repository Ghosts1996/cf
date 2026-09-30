#!/usr/bin/env python3
"""Пересборка списка блокировки рекламы: assets/adblock/adblock.srs.

Источники:
  * HaGeZi Multi PRO mini — версия списка для телефонов (домены из списков
    популярных), https://github.com/hagezi/dns-blocklists;
  * категория category-ads-all из v2fly (сборка SagerNet/sing-geosite);
  * EXTRAS ниже — российские рекламные сети и SDK рекламы в приложениях,
    которых нет в первых двух.
Из итога вычищаются домены из ALLOW — то, без чего не работает само
приложение (проверка обновлений, замер пинга) и крупные сервисы целиком.

Запуск из папки app/:
  python3 tool/adblock/build.py /путь/к/sing-box
Компилировать нужно тем же ядром, что стоит в приложении (форк
hiddify-sing-box из плагина), чтобы формат файла ему гарантированно подходил.
"""
import json
import subprocess
import sys
import tempfile
import urllib.request

HAGEZI = ('https://raw.githubusercontent.com/hagezi/dns-blocklists/main/'
          'wildcard/pro.mini-onlydomains.txt')
GEOSITE = ('https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/'
           'geosite-category-ads-all.srs')

EXTRAS = '''
yandexadexchange.net ads.mobile.yandex.net adsdk.yandex.ru an.yandex.ru
adfox.yandex.ru adfox.ru target.my.com ad.mail.ru r.mradx.net ads.vk.com
ad.vk.com ads.betweendigital.com ssp.rambler.ru imasdk.googleapis.com
pagead2.googlesyndication.com googleads.g.doubleclick.net appsflyer.com
appsflyersdk.com adjust.com adjust.world mintegral.com mintegral.net
rayjump.com mtgglobals.com pangle.io pangleglobal.com inmobi.com vungle.com
liftoff.io chartboost.com fyber.com moloco.com bidmachine.io adsbigo.com
startappservice.com adriver.ru buzzoola.com otm-r.com adhigh.net hybrid.ai
'''.split()

ALLOW = '''
github.com raw.githubusercontent.com objects.githubusercontent.com
release-assets.githubusercontent.com githubusercontent.com cp.cloudflare.com
cloudflare.com one.one.one.one gstatic.com www.gstatic.com
connectivitycheck.gstatic.com clients3.google.com googleapis.com
fcm.googleapis.com firebaseinstallations.googleapis.com play.googleapis.com
android.googleapis.com google.com youtube.com googlevideo.com ytimg.com
yandex.ru ya.ru yandex.net vk.com userapi.com mail.ru my.com telegram.org
t.me whatsapp.net whatsapp.com gosuslugi.ru sberbank.ru tbank.ru tinkoff.ru
'''.split()


def fetch(url):
    with urllib.request.urlopen(url, timeout=60) as r:
        return r.read()


def main():
    singbox = sys.argv[1]
    domains = {l.strip().lower() for l in fetch(HAGEZI).decode().splitlines()
               if l.strip() and not l.startswith('#')}
    with tempfile.TemporaryDirectory() as tmp:
        srs = f'{tmp}/geosite.srs'
        open(srs, 'wb').write(fetch(GEOSITE))
        subprocess.run([singbox, 'rule-set', 'decompile', srs,
                        '-o', f'{tmp}/geosite.json'], check=True)
        as_list = lambda v: [v] if isinstance(v, str) else v
        for rule in json.load(open(f'{tmp}/geosite.json'))['rules']:
            domains |= set(as_list(rule.get('domain', [])))
            domains |= {s.lstrip('.') for s in
                        as_list(rule.get('domain_suffix', []))}
        domains |= set(EXTRAS)
        for allowed in ALLOW:
            parts = allowed.split('.')
            for i in range(len(parts) - 1):
                domains.discard('.'.join(parts[i:]))
        result = sorted(d for d in domains if '.' in d and ' ' not in d)
        src = f'{tmp}/adblock.json'
        json.dump({'version': 2, 'rules': [{'domain_suffix': result}]},
                  open(src, 'w'), separators=(',', ':'))
        subprocess.run([singbox, 'rule-set', 'compile', src,
                        '-o', 'assets/adblock/adblock.srs'], check=True)
    print(f'{len(result)} доменов -> assets/adblock/adblock.srs')


if __name__ == '__main__':
    main()
