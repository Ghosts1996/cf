package dev.amirzr.singbox.service

import android.app.Service
import android.util.Log
import dev.amirzr.singbox.SingboxConstants
import dev.amirzr.singbox.engine.SingboxManager
import dev.amirzr.singbox.platform.StringListIterator
import io.nekohasekai.libbox.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach

/**
 * Stateless helper that manages the CommandServer lifecycle.
 * Receives all service configuration via [SessionOptions] at start time —
 * nothing is read from SharedPreferences or SingboxManager state.
 */
class BoxService(
    private val service: Service,
    private val platformInterface: PlatformInterface,
    private val manager: SingboxManager,
    private val config: SessionOptions,
    private val systemProxyAvailableInMode: Boolean,
) : CommandServerHandler {

    companion object {
        private const val TAG = "BoxService"
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var commandServer: CommandServer? = null

    // Service-local system proxy state (may be toggled by the Go core at runtime)
    @Volatile private var systemProxyEnabled = config.systemProxyEnabled

    fun start() {
        startTrafficNotificationUpdater()
        scope.launch {
            try {
                val server = CommandServer(this@BoxService, platformInterface)
                server.start()
                commandServer = server
                startCore()
            } catch (e: Exception) {
                Log.e(TAG, "Failed to start CommandServer", e)
                manager.notifyAlert("Start failed: ${e.message}")
                withContext(Dispatchers.Main) { service.stopSelf() }
            }
        }
    }

    private suspend fun startCore() {
        if (config.config.isBlank()) {
            manager.notifyAlert("No profile content provided")
            withContext(Dispatchers.Main) { service.stopSelf() }
            return
        }

        try {
            commandServer?.startOrReloadService(config.config, buildOverrideOptions())
        } catch (e: Exception) {
            Log.e(TAG, "Core start failed", e)
            manager.notifyAlert("Core failed: ${e.message}")
            withContext(Dispatchers.Main) { service.stopSelf() }
            return
        }

        Log.i(TAG, "Sing-box core started")
        manager.notifyServiceStarted()
    }

    private fun startTrafficNotificationUpdater() {
        if (!config.notification.showTrafficStats) return
        manager.trafficStats
            .filter { manager.serviceState.value == SingboxConstants.STATE_STARTED }
            .onEach { stats ->
                val up = (stats["uplinkBps"] as? Number)?.toLong() ?: 0L
                val down = (stats["downlinkBps"] as? Number)?.toLong() ?: 0L
                ServiceNotificationHelper.updateForTraffic(service, config.notification, up, down)
            }
            .launchIn(scope)
    }

    fun stop() {
        runCatching { commandServer?.closeService() }
        runCatching { commandServer?.close() }
        commandServer = null
        scope.cancel()
    }

    private fun buildOverrideOptions(): OverrideOptions {
        val opts = OverrideOptions()
        if (config.perAppProxyEnabled && config.perAppProxyList.isNotEmpty()) {
            when (config.perAppProxyMode) {
                "include" -> opts.includePackage = StringListIterator(config.perAppProxyList)
                "exclude" -> opts.excludePackage = StringListIterator(config.perAppProxyList)
            }
        }
        return opts
    }

    // ── CommandServerHandler ──────────────────────────────────────────────────

    override fun serviceStop() {
        Log.i(TAG, "serviceStop called by core")
        scope.launch(Dispatchers.Main) { service.stopSelf() }
    }

    override fun serviceReload() {
        scope.launch {
            runCatching {
                commandServer?.startOrReloadService(config.config, buildOverrideOptions())
            }
        }
    }

    override fun getSystemProxyStatus(): SystemProxyStatus? {
        val s = SystemProxyStatus()
        s.available = systemProxyAvailableInMode
        s.enabled = systemProxyAvailableInMode && systemProxyEnabled
        return s
    }

    override fun setSystemProxyEnabled(isEnabled: Boolean) {
        systemProxyEnabled = isEnabled
        serviceReload()
    }

    override fun triggerNativeCrash() {
        // no-op — crash injection not used in this SDK
    }

    override fun writeDebugMessage(message: String?) {
        Log.d("sing-box", message ?: "")
    }
}
