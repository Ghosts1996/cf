// Список рекламных и трекерных доменов для «Блокировки рекламы и трекеров».
//
// Раньше блокировка была списком из тринадцати доменов прямо в конфиге. Этого
// хватало на Google-аналитику и пару счётчиков, но не на рекламу внутри
// приложений: её показывают SDK рекламных сетей (Яндекс, VK/myTarget, AppLovin,
// Unity, Mintegral, Pangle…), и ни одного из них в том списке не было. Отсюда
// реклама в Zona и подобных приложениях при включённом тумблере.
//
// Теперь список — около 60 тысяч доменов (HaGeZi Multi PRO mini — версия для
// телефонов, где только домены из списков популярных, плюс категория
// ads-all из v2fly и российские рекламные сети сверху). Это уже скомпилированный
// ядром двоичный rule-set (.srs, ~470 КБ): в JSON-конфиге такой список весил бы
// больше мегабайта и разбирался бы заново при каждом подключении и каждой
// проверке. Ядро читает файл с диска по пути, поэтому файл из ассетов один раз
// копируется в папку приложения.
//
// Как пересобрать — см. tool/adblock/README.md.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

class AdBlockRules {
  AdBlockRules._();

  static const assetPath = 'assets/adblock/adblock.srs';

  /// Имя файла на диске. Сам файл сверяется с ассетом по размеру, так что
  /// обновлённый список в новой версии приложения заменит старый и без смены
  /// имени.
  static const fileName = 'adblock.srs';

  static String? _readyPath;
  static Future<String?>? _inFlight;

  /// Путь к файлу списка на диске, готовому для ядра. null — файл положить не
  /// удалось: тогда блокировка работает по короткому встроенному списку, а
  /// подключение не страдает.
  static Future<String?> ensureFile({
    Future<Directory> Function()? directory,
    Future<ByteData> Function(String key)? loadAsset,
  }) {
    final ready = _readyPath;
    if (ready != null && File(ready).existsSync()) {
      return Future<String?>.value(ready);
    }
    return _inFlight ??= _prepare(
      directory ?? getApplicationSupportDirectory,
      loadAsset ?? rootBundle.load,
    ).whenComplete(() => _inFlight = null);
  }

  static Future<String?> _prepare(
    Future<Directory> Function() directory,
    Future<ByteData> Function(String key) loadAsset,
  ) async {
    try {
      final data = await loadAsset(assetPath);
      final bytes =
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      if (bytes.isEmpty) return null;
      final dir = await directory();
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final file = File('${dir.path}${Platform.pathSeparator}$fileName');
      if (!file.existsSync() || file.lengthSync() != bytes.length) {
        // Через временный файл: ядро не должно увидеть недописанный список —
        // на битом файле оно отказалось бы стартовать вообще.
        final tmp = File('${file.path}.tmp');
        await tmp.writeAsBytes(bytes, flush: true);
        if (file.existsSync()) file.deleteSync();
        tmp.renameSync(file.path);
      }
      _readyPath = file.path;
      return file.path;
    } catch (_) {
      return null;
    }
  }

  @visibleForTesting
  static void debugReset() {
    _readyPath = null;
    _inFlight = null;
  }
}
