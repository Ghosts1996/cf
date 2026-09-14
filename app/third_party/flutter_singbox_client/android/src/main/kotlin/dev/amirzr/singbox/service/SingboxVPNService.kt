package dev.amirzr.singbox.service

import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.IpPrefix
import android.net.ProxyInfo
import android.net.VpnService
import android.os.Build
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
import java.net.InetAddress

class SingboxVPNService : VpnService(), BoxPlatformInterface {

    companion object {
        private const val TAG = "SingboxVPNService"

        // Published to the system as the VPN's resolvers. Their traffic is
        // intercepted by sing-box (`hijack-dns`) and never reaches these
        // addresses; they only have to look like a valid resolver to Android.
        private const val VPN_DNS_V4 = "1.1.1.1"
        private const val VPN_DNS_V6 = "2606:4700:4700::1111"

        @Volatile
        var instance: SingboxVPNService? = null
            private set
    }

    override val boxContext: Context get() = applicationContext
    override val boxConnectivityManager: ConnectivityManager by lazy {
        getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager
    }

    private val manager by lazy { SingboxManager.getInstance(this) }
    private val stopScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private var helper: BoxService? = null
    private var tunFd: android.os.ParcelFileDescriptor? = null
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
        if (prepare(this) != null) {
            Log.w(TAG, "VPN permission not granted")
            manager.notifyAlert("VPN permission required")
            stopSelf()
            return START_NOT_STICKY
        }

        serviceConfig = parseConfig(intent)

        val notif = ServiceNotificationHelper.buildNotification(
            this, serviceConfig.notification, serviceConfig.notification.title
        )
        startForeground(SingboxConstants.NOTIFICATION_ID, notif)
        manager.notifyServiceState(SingboxConstants.STATE_STARTING)

        val monitor = DefaultNetworkMonitor(applicationContext)
        networkMonitor = monitor
        monitor.startMonitoring()

        val boxService = BoxService(this, this, manager, serviceConfig, systemProxyAvailableInMode = true)
        helper = boxService
        boxService.start()

        return START_STICKY
    }

    override fun onRevoke() {
        Log.i(TAG, "VPN revoked by system")
        stopGracefully()
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
            tunFd?.close()
            tunFd = null
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
            tunFd?.close()
            tunFd = null
            manager.notifyServiceState(SingboxConstants.STATE_STOPPED)
        }
        stopScope.cancel()
        instance = null
        super.onDestroy()
    }

    override fun onBind(intent: Intent?) = super.onBind(intent)

    // ── PlatformInterface ─────────────────────────────────────────────────────

    override fun autoDetectInterfaceControl(fd: Int) { protect(fd) }

    override fun startDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        networkMonitor?.setListener(listener)
    }

    override fun closeDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        networkMonitor?.clearListener()
    }

    override fun openTun(options: TunOptions): Int {
        if (prepare(this) != null) {
            Log.w(TAG, "openTun: VPN permission not granted")
            manager.notifyAlert("VPN permission required")
            return -1
        }

        val builder = Builder()
            .setSession("sing-box")
            .setMtu(options.mtu)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) builder.setMetered(false)
        if (serviceConfig.killSwitch && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) builder.setBlocking(true)
        if (serviceConfig.allowBypass && !serviceConfig.killSwitch) builder.allowBypass()

        val inet4 = options.inet4Address
        while (inet4.hasNext()) { val a = inet4.next(); runCatching { builder.addAddress(a.address(), a.prefix()) } }
        val inet6 = options.inet6Address
        // Итератор libbox одноразовый: пройденный здесь, ниже он уже пуст,
        // поэтому наличие IPv6 запоминаем флагом.
        var hasInet6 = false
        while (inet6.hasNext()) {
            val a = inet6.next()
            hasInet6 = true
            runCatching { builder.addAddress(a.address(), a.prefix()) }
        }

        if (options.autoRoute) {
            // A VPN that publishes no DNS server at all is a dead end on the
            // ROMs that do not fall back to the underlying network's resolvers:
            // apps get no resolver, every hostname fails, and the tunnel looks
            // "connected" while nothing loads.
            //
            // libbox's own synthetic TUN address is not used here on purpose:
            // nothing listens on its port 853, and Android's Private DNS
            // probe validates the VPN resolver as DNS-over-TLS first — the
            // failed probe then blocks resolution outright. A real public
            // resolver address has no such problem: the probe succeeds, and
            // the queries themselves never leave the device anyway, because
            // the route rule `hijack-dns` picks them up inside sing-box and
            // answers them from the configured DNS block.
            val dnsServers = mutableListOf(VPN_DNS_V4)
            if (hasInet6) dnsServers.add(VPN_DNS_V6)
            dnsServers.forEach { runCatching { builder.addDnsServer(it) } }

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                val r4 = options.inet4RouteAddress
                if (r4.hasNext()) { while (r4.hasNext()) { val a = r4.next(); runCatching { builder.addRoute(a.address(), a.prefix()) } } }
                else if (options.inet4Address.hasNext()) builder.addRoute("0.0.0.0", 0)

                val r6 = options.inet6RouteAddress
                if (r6.hasNext()) { while (r6.hasNext()) { val a = r6.next(); runCatching { builder.addRoute(a.address(), a.prefix()) } } }
                else if (options.inet6Address.hasNext()) builder.addRoute("::", 0)

                val ex4 = options.inet4RouteExcludeAddress
                while (ex4.hasNext()) { val a = ex4.next(); runCatching { builder.excludeRoute(IpPrefix(InetAddress.getByName(a.address()), a.prefix())) } }
                val ex6 = options.inet6RouteExcludeAddress
                while (ex6.hasNext()) { val a = ex6.next(); runCatching { builder.excludeRoute(IpPrefix(InetAddress.getByName(a.address()), a.prefix())) } }
            } else {
                val r4 = options.inet4RouteRange
                while (r4.hasNext()) { val a = r4.next(); runCatching { builder.addRoute(a.address(), a.prefix()) } }
                val r6 = options.inet6RouteRange
                while (r6.hasNext()) { val a = r6.next(); runCatching { builder.addRoute(a.address(), a.prefix()) } }
            }

            val incPkg = options.includePackage
            while (incPkg.hasNext()) { runCatching { builder.addAllowedApplication(incPkg.next()) } }
            val excPkg = options.excludePackage
            while (excPkg.hasNext()) { runCatching { builder.addDisallowedApplication(excPkg.next()) } }
        }

        if (options.isHTTPProxyEnabled && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            if (serviceConfig.systemProxyEnabled) {
                val bypass = mutableListOf<String>()
                val domains = options.httpProxyBypassDomain
                while (domains.hasNext()) bypass.add(domains.next())
                builder.setHttpProxy(ProxyInfo.buildDirectProxy(options.httpProxyServer, options.httpProxyServerPort, bypass))
            }
        }

        val pfd = builder.establish() ?: run { Log.e(TAG, "establish() returned null"); return -1 }
        tunFd = pfd
        return pfd.fd
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
