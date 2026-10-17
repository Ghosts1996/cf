package su.vpnonline.vpnonline_app

import android.Manifest
import android.app.ActivityManager
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.TrafficStats
import android.net.Uri
import android.net.VpnService
import android.os.Build
import android.os.Process
import android.provider.Settings
import androidx.annotation.NonNull
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import java.io.File
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
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
                    "hasVpnPermission" -> result.success(hasVpnPermission())
                    "updateVpnNotification" -> {
                        updateVpnNotification(call)
                        result.success(null)
                    }
                    "clearVpnNotification" -> {
                        clearVpnNotification()
                        result.success(null)
                    }
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

    /// Есть ли у приложения разрешение на VPN — без системного диалога.
    /// Восстановление туннеля из фона спрашивает здесь: запрос разрешения
    /// через плагин открыл бы системное окно поверх чужого приложения (так
    /// бывает, когда VPN забрало другое VPN-приложение).
    private fun hasVpnPermission(): Boolean? = try {
        VpnService.prepare(this) == null
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

    // ── Уведомление VPN ──────────────────────────────────────────────────

    /// Уведомление работающего VPN рисует модуль ядра, и выглядит оно бедно:
    /// цветная иконка приложения вместо значка (Android превращает её в пятно
    /// в кружке) и одна строка «VPN подключён». Поменять это в самом модуле
    /// значит трогать его ветку, поэтому приложение обновляет то же
    /// уведомление само: тот же канал и тот же номер, что у модуля, — Android
    /// подменяет содержимое, а уведомление остаётся привязанным к сервису.
    private val vpnNotificationId = 1001
    private val vpnNotificationChannel = "singbox_service"
    private val brandColor = 0xFF8B5CF6.toInt()

    /// Работает ли сервис ядра. Без него уведомление не публикуем: иначе
    /// после отключения в шторке остался бы «VPN подключён» без VPN.
    private fun coreServiceRunning(): Boolean =
        dev.amirzr.singbox.service.SingboxVPNService.instance != null ||
            dev.amirzr.singbox.service.SingboxProxyService.instance != null

    private fun updateVpnNotification(call: MethodCall) {
        if (!coreServiceRunning()) return
        try {
            val title = call.argument<String>("title") ?: "VPN подключён"
            val text = call.argument<String>("text")
            val details = call.argument<String>("details")
            val since = call.argument<Number>("since")?.toLong() ?: 0L
            val stopLabel = call.argument<String>("stopLabel") ?: "Отключить"

            val openApp = packageManager.getLaunchIntentForPackage(packageName)?.let {
                it.flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
                PendingIntent.getActivity(
                    this, 0, it,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                )
            }
            // Та же кнопка «Отключить», что ставит модуль: его приёмник
            // останавливает сервис ядра.
            val stop = PendingIntent.getBroadcast(
                this, 1,
                Intent().setClassName(
                    packageName,
                    "dev.amirzr.singbox.receivers.NotificationStopReceiver",
                ).setAction("dev.amirzr.singbox.STOP"),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            // На экране блокировки — без сервера и ключа.
            val lockScreen = NotificationCompat.Builder(this, vpnNotificationChannel)
                .setSmallIcon(R.drawable.ic_stat_vpn)
                .setColor(brandColor)
                .setContentTitle("VPN подключён")
                .build()

            val builder = NotificationCompat.Builder(this, vpnNotificationChannel)
                .setSmallIcon(R.drawable.ic_stat_vpn)
                .setColor(brandColor)
                .setContentTitle(title)
                .setContentText(text)
                .setStyle(NotificationCompat.BigTextStyle().bigText(details ?: text))
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setSilent(true)
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .setCategory(NotificationCompat.CATEGORY_SERVICE)
                .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
                .setPublicVersion(lockScreen)
                .setForegroundServiceBehavior(
                    NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE,
                )
                .addAction(R.drawable.ic_stat_power, stopLabel, stop)
            if (openApp != null) builder.setContentIntent(openApp)
            // Время сессии считает сама система — без обновлений
            // уведомления каждую секунду.
            if (since > 0) {
                builder.setWhen(since).setShowWhen(true).setUsesChronometer(true)
            }
            getSystemService(NotificationManager::class.java)
                .notify(vpnNotificationId, builder.build())
        } catch (e: Exception) {
            // Нет разрешения на уведомления или система отказала — VPN от
            // этого не зависит, остаётся уведомление модуля.
        }
    }

    /// Убирает уведомление, оставшееся без сервиса. Пока сервис работает
    /// (например, проверка серверов), не трогаем: это его уведомление.
    private fun clearVpnNotification() {
        if (coreServiceRunning()) return
        try {
            getSystemService(NotificationManager::class.java).cancel(vpnNotificationId)
        } catch (_: Exception) {
        }
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