
package su.vpnonline.vpnonline_app

import android.Manifest
import android.content.pm.PackageManager
import android.net.TrafficStats
import android.os.Build
import android.os.Process
import androidx.annotation.NonNull
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/// [ИСПРАВЛЕНО — реальный баг со скриншота "нет VPN-уведомления в шторке,
/// не показывает приём/отдачу"]
///
/// У Dart-стороны (services/tunnel_service.dart) уже давно есть код,
/// который дёргает MethodChannel("vpnonline/native_stats") с методами
/// `requestNotificationPermission` (вызывается из connect() перед подъёмом
/// туннеля) и `getUidTraffic` (фолбэк-поллинг RX/TX в _pollNativeTraffic()).
/// Но здесь, на нативной Kotlin-стороне, этот канал НИКОГДА не был
/// реализован — раньше MainActivity была пустым
/// `class MainActivity : FlutterActivity()` без единой строчки обработки
/// метод-каналов. Любой вызов на этом канале падал с
/// MissingPluginException, которую Dart-сторона молча проглатывает (см.
/// комментарий в connect() — "разрешение на уведомления влияет только на
/// видимость статус-бара, а не на безопасность туннеля", поэтому VPN
/// формально продолжал работать). Из-за этого:
///
/// 1. На Android 13+ (API 33+) runtime-разрешение POST_NOTIFICATIONS
///    никогда реально не запрашивалось — объявления в AndroidManifest.xml
///    для "опасных" runtime-разрешений недостаточно, начиная с API 33 нужен
///    ещё и системный диалог. Без выданного разрешения Android скрывает
///    ПОСТОЯННОЕ уведомление foreground VPN-сервиса из шторки, хотя сам
///    сервис/туннель работает нормально — ровно то, что видно на
///    скриншоте (шторка пустая, "Нет уведомлений").
/// 2. Нативный fallback для RX/TX (_pollNativeTraffic()) тоже всегда молча
///    падал и никогда не подставлял реальные счётчики трафика.
///
/// Здесь оба метода реализованы по стандартному Android API — без
/// сторонних зависимостей, androidx.core уже транзитивно тянется самим
/// Flutter embedding v2.
class MainActivity : FlutterActivity() {
    private val channelName = "vpnonline/native_stats"
    private val notificationPermissionRequestCode = 4771

    // Единственный незавершённый MethodChannel.Result, ожидающий ответа
    // системного диалога разрешений (см. requestNotificationPermission /
    // onRequestPermissionsResult ниже) — Android доставляет результат
    // асинхронным колбэком Activity, а не сразу из вызова
    // ActivityCompat.requestPermissions(), поэтому Result нужно сохранить
    // между двумя методами.
    private var pendingPermissionResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "requestNotificationPermission" -> requestNotificationPermission(result)
                    "getUidTraffic" -> result.success(getUidTraffic())
                    else -> result.notImplemented()
                }
            }
    }

    /// POST_NOTIFICATIONS как отдельное runtime-разрешение существует
    /// только начиная с Android 13 (API 33, TIRAMISU) — на более старых
    /// версиях показ уведомлений foreground-сервиса подтверждения
    /// пользователя не требует, поэтому там сразу честно отвечаем true.
    private fun requestNotificationPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            result.success(true)
            return
        }
        val alreadyGranted = ContextCompat.checkSelfPermission(
            this, Manifest.permission.POST_NOTIFICATIONS
        ) == PackageManager.PERMISSION_GRANTED
        if (alreadyGranted) {
            result.success(true)
            return
        }
        if (pendingPermissionResult != null) {
            // Уже есть незавершённый запрос (например, двойной тап на
            // "Подключить") — не плодим второй системный диалог поверх
            // первого, честно отвечаем false именно этому вызову.
            result.success(false)
            return
        }
        pendingPermissionResult = result
        ActivityCompat.requestPermissions(
            this,
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            notificationPermissionRequestCode
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != notificationPermissionRequestCode) return
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        pendingPermissionResult?.success(granted)
        pendingPermissionResult = null
    }

    /// Суммарные rx/tx байты именно UID этого приложения с момента загрузки
    /// устройства (см. докстринг _pollNativeTraffic() в tunnel_service.dart
    /// — он сам считает разницу между двумя опросами, абсолютное значение
    /// здесь не важно). TrafficStats.UNSUPPORTED означает, что счётчик
    /// недоступен на этом ядре/устройстве — в этом случае отдаём null, а не
    /// -1, чтобы Dart-сторона не приняла -1 за реальный (и ещё и
    /// отрицательный) трафик.
    private fun getUidTraffic(): Map<String, Any?> {
        val uid = Process.myUid()
        val rx = TrafficStats.getUidRxBytes(uid)
        val tx = TrafficStats.getUidTxBytes(uid)
        val unsupported = TrafficStats.UNSUPPORTED.toLong()
        return mapOf(
            "rxBytes" to if (rx == unsupported) null else rx,
            "txBytes" to if (tx == unsupported) null else tx
        )
    }
}