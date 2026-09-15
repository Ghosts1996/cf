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

/// Нативная часть канала MethodChannel("vpnonline/native_stats"), который
/// дёргает services/tunnel_service.dart:
///
/// 1. `requestNotificationPermission` — на Android 13+ (API 33+) одного
///    объявления POST_NOTIFICATIONS в манифесте мало, нужен ещё системный
///    диалог. Без выданного разрешения ОС прячет постоянное уведомление
///    foreground VPN-сервиса из шторки, хотя сам туннель работает.
/// 2. `getUidTraffic` — фолбэк-счётчики RX/TX для _pollNativeTraffic().
/// 3. `getPackageName` — имя пакета для исключения самого приложения из
///    туннеля.
///
/// Всё на стандартном Android API: androidx.core уже транзитивно приходит
/// с Flutter embedding v2.
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
                    // Имя пакета берём у системы, а не константой: с
                    // applicationIdSuffix для debug- или flavor-сборок
                    // константа станет неверной, и Android отвергнет
                    // addDisallowedApplication с NameNotFoundException —
                    // VPN перестанет подниматься.
                    "getPackageName" -> result.success(packageName)
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