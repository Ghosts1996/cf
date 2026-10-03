package su.vpnonline.vpnonline_app

import android.Manifest
import android.app.ActivityManager
import android.content.Intent
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.TrafficStats
import android.net.Uri
import android.os.Build
import android.os.Process
import android.provider.Settings
import androidx.annotation.NonNull
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import java.io.File
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
/// 4. `getUpdatesDir`, `canInstallPackages`, `openInstallPermissionSettings`,
///    `installApk` — обновление приложения без браузера
///    (services/update_installer.dart).
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
                    "isVpnActive" -> result.success(isVpnActive())
                    "isCoreServiceAlive" -> result.success(isCoreServiceAlive())
                    "restartApp" -> {
                        result.success(null)
                        restartApp()
                    }
                    "getUpdatesDir" -> result.success(updatesDir().absolutePath)
                    "canInstallPackages" -> result.success(canInstallPackages())
                    "openInstallPermissionSettings" -> {
                        openInstallPermissionSettings()
                        result.success(null)
                    }
                    "installApk" -> installApk(call.argument<String>("path"), result)
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

    /// Есть ли сейчас в системе VPN-сеть. Независимая от плагина проверка:
    /// плагин считает сессию живой, пока к нему подключён клиент команд ядра,
    /// и может сказать «работает», когда самого VPN-интерфейса уже нет.
    /// null — спросить не удалось.
    @Suppress("DEPRECATION")
    private fun isVpnActive(): Boolean? = try {
        val cm = getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager
        cm.allNetworks.any {
            cm.getNetworkCapabilities(it)
                ?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true
        }
    } catch (e: Exception) {
        null
    }

    /// Жив ли ещё сервис ядра (VPN или прокси) из плагина. Плагин сообщает
    /// «остановлено» раньше, чем Android уничтожает сам сервис, и новый старт
    /// в эту щель теряет старое ядро — оно остаётся жить без VPN. Приложение
    /// ждёт по этому ответу, пока сервис не уйдёт целиком.
    /// getRunningServices устарел, но свои сервисы приложению отдаёт.
    @Suppress("DEPRECATION")
    private fun isCoreServiceAlive(): Boolean? = try {
        val am = getSystemService(ACTIVITY_SERVICE) as ActivityManager
        am.getRunningServices(Int.MAX_VALUE).any {
            it.service.packageName == packageName &&
                (it.service.className.endsWith("SingboxVPNService") ||
                    it.service.className.endsWith("SingboxProxyService"))
        }
    } catch (e: Exception) {
        null
    }

    /// Перезапуск процесса приложения — см. RestartActivity.
    private fun restartApp() {
        val intent = Intent(this, RestartActivity::class.java).apply {
            putExtra(RestartActivity.EXTRA_MAIN_PID, Process.myPid())
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(intent)
    }

    /// Папка для загруженного обновления. Та же, что открыта наружу в
    /// res/xml/update_paths.xml, — и только она.
    private fun updatesDir(): File = File(cacheDir, "updates").apply { mkdirs() }

    /// «Установка неизвестных приложений» для этого приложения. Такая
    /// настройка есть с Android 8 (API 26); раньше разрешение давалось
    /// одним общим переключателем, и спрашивать было не у кого.
    private fun canInstallPackages(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            packageManager.canRequestPackageInstalls()
        } else {
            true
        }

    private fun openInstallPermissionSettings() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        startActivity(
            Intent(
                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:$packageName")
            )
        )
    }

    /// Передаёт загруженный APK системному установщику. Android покажет своё
    /// окно «Обновить приложение?» — молча ставить пакеты обычное приложение
    /// не может. Пакет и ключ подписи те же, поэтому новая версия встаёт
    /// поверх старой с сохранением всех данных.
    private fun installApk(path: String?, result: MethodChannel.Result) {
        if (path == null) {
            result.error("NO_PATH", "Не передан путь к файлу", null)
            return
        }
        val file = File(path)
        // Отдаём наружу только то, что лежит в папке обновлений: канал
        // внутренний, но лишняя проверка здесь ничего не стоит.
        val dir = updatesDir().canonicalPath + File.separator
        if (!file.canonicalPath.startsWith(dir)) {
            result.error("BAD_PATH", "Файл вне папки обновлений", null)
            return
        }
        if (!file.isFile) {
            result.error("NO_FILE", "Файла обновления нет", null)
            return
        }
        try {
            val uri = FileProvider.getUriForFile(this, "$packageName.updates", file)
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                        Intent.FLAG_ACTIVITY_NEW_TASK
                )
            }
            startActivity(intent)
            result.success(null)
        } catch (e: Exception) {
            result.error("INSTALL_FAILED", e.message, null)
        }
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