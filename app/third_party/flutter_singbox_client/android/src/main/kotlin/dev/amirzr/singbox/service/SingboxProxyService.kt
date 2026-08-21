package dev.amirzr.singbox.service

import android.app.Service
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.util.Log
import androidx.core.app.ServiceCompat
import dev.amirzr.singbox.SingboxConstants
import dev.amirzr.singbox.engine.SingboxEngine
import dev.amirzr.singbox.engine.SingboxManager
import dev.amirzr.singbox.network.DefaultNetworkMonitor
import dev.amirzr.singbox.platform.BoxPlatformInterface
import io.nekohasekai.libbox.*
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject

class SingboxProxyService : Service(), BoxPlatformInterface {

    companion object {
        private const val TAG = "SingboxProxyService"

        @Volatile
        var instance: SingboxProxyService? = null
            private set
    }

    override val boxContext: Context get() = applicationContext
    override val boxConnectivityManager: ConnectivityManager by lazy {
        getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager
    }

    private val manager by lazy { SingboxManager.getInstance(this) }
    private val stopScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private var helper: BoxService? = null
    private var networkMonitor: DefaultNetworkMonitor? = null
    @Volatile private var stopping = false

    private var serviceConfig: SessionOptions = SessionOptions(config = "")

    override fun onCreate() {
        super.onCreate()
        SingboxEngine.ensureInitialized(applicationContext)
        instance = this
        ServiceNotificationHelper.createChannel(this, SessionOptions(config = "").notification)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        serviceConfig = parseConfig(intent)

        val notif = ServiceNotificationHelper.buildNotification(
            this, serviceConfig.notification, serviceConfig.notification.title
        )
        startForeground(SingboxConstants.NOTIFICATION_ID, notif)
        manager.notifyServiceState(SingboxConstants.STATE_STARTING)

        val monitor = DefaultNetworkMonitor(applicationContext)
        networkMonitor = monitor
        monitor.startMonitoring()

        val boxService = BoxService(this, this, manager, serviceConfig, systemProxyAvailableInMode = false)
        helper = boxService
        boxService.start()

        return START_STICKY
    }

    fun stopGracefully() {
        if (stopping) return
        stopping = true
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        stopScope.launch {
            networkMonitor?.stopMonitoring()
            networkMonitor = null
            helper?.stop()
            helper = null
            manager.notifyServiceState(SingboxConstants.STATE_STOPPED)
            withContext(Dispatchers.Main) { stopSelf() }
        }
    }

    override fun onDestroy() {
        if (!stopping) {
            stopping = true
            ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
            networkMonitor?.stopMonitoring()
            networkMonitor = null
            helper?.stop()
            helper = null
            manager.notifyServiceState(SingboxConstants.STATE_STOPPED)
        }
        stopScope.cancel()
        instance = null
        super.onDestroy()
    }

    override fun onBind(intent: Intent?) = null

    // ── PlatformInterface ─────────────────────────────────────────────────────

    override fun openTun(options: TunOptions): Int = -1
    override fun autoDetectInterfaceControl(fd: Int) {}

    override fun startDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        networkMonitor?.setListener(listener)
    }

    override fun closeDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        networkMonitor?.clearListener()
    }

    override fun sendNotification(notification: Notification) {
        Log.d(TAG, "core notification: ${notification.title} — ${notification.body}")
    }

    private fun parseConfig(intent: Intent?): SessionOptions {
        val json = intent?.getStringExtra(SessionOptions.EXTRA_KEY) ?: return SessionOptions(config = "")
        return try {
            SessionOptions.fromMap(SessionOptions.jsonObjectToMap(JSONObject(json)))
        } catch (e: Exception) {
            Log.e(TAG, "Failed to parse SessionOptions", e)
            SessionOptions(config = "")
        }
    }
}
