package su.vpnonline.vpnonline_app

import android.Manifest
import android.content.pm.PackageManager
import android.net.TrafficStats
import android.os.Build
import android.os.Process
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private var notificationPermissionResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "vpnonline/native_stats"
        ).setMethodCallHandler { call, result ->
            if (call.method == "requestNotificationPermission") {
                requestNotificationPermission(result)
                return@setMethodCallHandler
            }
            if (call.method != "getUidTraffic") {
                result.notImplemented()
                return@setMethodCallHandler
            }

            val uid = Process.myUid()
            val tunRx = readCounter("/sys/class/net/tun0/statistics/rx_bytes")
            val tunTx = readCounter("/sys/class/net/tun0/statistics/tx_bytes")
            result.success(
                mapOf(
                    // tun0.rx — пакеты приложений, ушедшие в VPN (upload),
                    // tun0.tx — ответы, возвращённые VPN приложениям (download).
                    "rxBytes" to (tunTx
                        ?: TrafficStats.getUidRxBytes(uid).coerceAtLeast(0L)),
                    "txBytes" to (tunRx
                        ?: TrafficStats.getUidTxBytes(uid).coerceAtLeast(0L)),
                )
            )
        }
    }

    private fun requestNotificationPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) ==
                PackageManager.PERMISSION_GRANTED) {
            result.success(true)
            return
        }
        if (notificationPermissionResult != null) {
            result.success(false)
            return
        }
        notificationPermissionResult = result
        ActivityCompat.requestPermissions(
            this,
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            REQUEST_NOTIFICATION_PERMISSION,
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQUEST_NOTIFICATION_PERMISSION) return
        val granted = grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED
        notificationPermissionResult?.success(granted)
        notificationPermissionResult = null
    }

    private fun readCounter(path: String): Long? =
        runCatching { File(path).readText().trim().toLong() }.getOrNull()

    private companion object {
        const val REQUEST_NOTIFICATION_PERMISSION = 1901
    }
}
