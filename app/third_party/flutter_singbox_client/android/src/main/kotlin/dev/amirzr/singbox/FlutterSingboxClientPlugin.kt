package dev.amirzr.singbox

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.util.Log
import dev.amirzr.singbox.engine.SingboxEngine
import dev.amirzr.singbox.engine.SingboxManager
import dev.amirzr.singbox.service.SessionOptions
import dev.amirzr.singbox.service.SingboxProxyService
import dev.amirzr.singbox.service.SingboxVPNService
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.NetworkQualityProgress
import io.nekohasekai.libbox.NetworkQualityTestHandler
import io.nekohasekai.libbox.STUNTestHandler
import io.nekohasekai.libbox.STUNTestProgress
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry.ActivityResultListener
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach

class FlutterSingboxClientPlugin :
    FlutterPlugin,
    ActivityAware,
    ActivityResultListener {

    companion object {
        private const val TAG = "SingboxClientPlugin"
        private const val VPN_PERMISSION_REQUEST = 0xBEEF
    }

    private lateinit var methodChannel: MethodChannel
    private lateinit var stateEventChannel: EventChannel
    private lateinit var trafficEventChannel: EventChannel
    private lateinit var coreLogEventChannel: EventChannel
    private lateinit var connectionEventChannel: EventChannel
    private lateinit var groupEventChannel: EventChannel
    private lateinit var clashModeEventChannel: EventChannel
    private lateinit var clashModesEventChannel: EventChannel
    private lateinit var faultEventChannel: EventChannel
    private lateinit var networkQualityEventChannel: EventChannel
    private lateinit var stunEventChannel: EventChannel

    private var appContext: Context? = null
    private var activity: Activity? = null
    private var vpnPermissionResult: MethodChannel.Result? = null

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    private lateinit var manager: SingboxManager

    // Sinks for one-shot test channels (not backed by manager flows)
    private var networkQualitySink: EventChannel.EventSink? = null
    private var stunSink: EventChannel.EventSink? = null

    // Network quality test cancellation handles
    private var networkQualityTest: io.nekohasekai.libbox.NetworkQualityTest? = null
    private var networkQualityJob: kotlinx.coroutines.Job? = null

    // STUN test cancellation handles
    private var stunTest: io.nekohasekai.libbox.STUNTest? = null
    private var stunJob: kotlinx.coroutines.Job? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val ctx = binding.applicationContext
        appContext = ctx

        manager = SingboxManager.getInstance(ctx)

        methodChannel = MethodChannel(binding.binaryMessenger, SingboxConstants.CHANNEL)
        methodChannel.setMethodCallHandler(::onMethodCall)

        stateEventChannel = EventChannel(binding.binaryMessenger, SingboxConstants.STATE_CHANNEL)
        trafficEventChannel = EventChannel(binding.binaryMessenger, SingboxConstants.TRAFFIC_CHANNEL)
        coreLogEventChannel = EventChannel(binding.binaryMessenger, SingboxConstants.LOG_CHANNEL)
        connectionEventChannel = EventChannel(binding.binaryMessenger, SingboxConstants.CONNECTION_CHANNEL)
        groupEventChannel = EventChannel(binding.binaryMessenger, SingboxConstants.GROUP_CHANNEL)
        clashModeEventChannel = EventChannel(binding.binaryMessenger, SingboxConstants.CLASH_MODE_CHANNEL)
        clashModesEventChannel = EventChannel(binding.binaryMessenger, SingboxConstants.CLASH_MODES_CHANNEL)
        faultEventChannel = EventChannel(binding.binaryMessenger, SingboxConstants.ALERT_CHANNEL)
        networkQualityEventChannel = EventChannel(binding.binaryMessenger, SingboxConstants.NETWORK_QUALITY_CHANNEL)
        stunEventChannel = EventChannel(binding.binaryMessenger, SingboxConstants.STUN_CHANNEL)

        setupEventChannels()
    }

    private fun setupEventChannels() {
        // Manager-backed flows: emit directly to the Flutter sink, no sink field needed.
        stateEventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink) {
                manager.serviceState.onEach { sink.success(it) }.launchIn(scope)
            }
            override fun onCancel(args: Any?) {}
        })

        trafficEventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink) {
                manager.trafficStats.onEach { sink.success(it) }.launchIn(scope)
            }
            override fun onCancel(args: Any?) {}
        })

        coreLogEventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink) {
                manager.logs.onEach { sink.success(it) }.launchIn(scope)
            }
            override fun onCancel(args: Any?) {}
        })

        connectionEventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink) {
                manager.connections.onEach { sink.success(it) }.launchIn(scope)
            }
            override fun onCancel(args: Any?) {}
        })

        groupEventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink) {
                manager.groups.onEach { sink.success(it) }.launchIn(scope)
            }
            override fun onCancel(args: Any?) {}
        })

        clashModeEventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink) {
                manager.clashMode.onEach { sink.success(it) }.launchIn(scope)
            }
            override fun onCancel(args: Any?) {}
        })

        clashModesEventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink) {
                manager.clashModes.onEach { sink.success(it) }.launchIn(scope)
            }
            override fun onCancel(args: Any?) {}
        })

        faultEventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink) {
                manager.alerts.onEach { sink.success(it) }.launchIn(scope)
            }
            override fun onCancel(args: Any?) {}
        })

        // Test channels: sink is held so progress/result can be pushed from callbacks.
        networkQualityEventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink) {
                networkQualitySink = sink
            }
            override fun onCancel(args: Any?) {
                networkQualitySink = null
                cancelNetworkQualityTest()
            }
        })

        stunEventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink) {
                stunSink = sink
            }
            override fun onCancel(args: Any?) {
                stunSink = null
                cancelStunTest()
            }
        })
    }

    // ── Method dispatch ────────────────────────────────────────────────────

    private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {

            // ── Lifecycle ────────────────────────────────────────────────
            "initialize" -> handleInitialize(call, result)
            "requestVPNPermission" -> handleRequestVpnPermission(result)
            "connect" -> handleConnect(call, result)
            "disconnect" -> { manager.disconnect(); result.success(null) }
            "reloadConfig" -> { manager.reloadConfig(); result.success(null) }
            "getServiceState" -> result.success(manager.serviceState.value)
            "getVersion" -> result.success(SingboxConstants.PLUGIN_VERSION)
            "getCoreVersion" -> result.success(SingboxEngine.version())

            // ── Config ───────────────────────────────────────────────────
            "checkConfig" -> handleCheckConfig(call, result)
            "formatConfig" -> handleFormatConfig(call, result)

            // ── Outbounds ────────────────────────────────────────────────
            "selectOutbound" -> handleSelectOutbound(call, result)
            "urlTest" -> handleUrlTest(call, result)

            // ── Clash mode ───────────────────────────────────────────────
            "setClashMode" -> { manager.setClashMode(call.argument("mode") ?: ""); result.success(null) }

            // ── Connections ──────────────────────────────────────────────
            "closeConnection" -> { manager.closeConnection(call.argument("id") ?: ""); result.success(null) }
            "closeAllConnections" -> { manager.closeAllConnections(); result.success(null) }

            // ── Traffic ──────────────────────────────────────────────────
            "getTrafficStats" -> result.success(manager.getTrafficSnapshot())

            // ── System proxy ─────────────────────────────────────────────
            "getSystemProxyStatus" -> result.success(manager.getSystemProxyStatus())
            "setSystemProxyEnabled" -> { manager.setSystemProxyEnabled(call.argument("enabled") ?: false); result.success(null) }

            // ── Network testing ──────────────────────────────────────────
            "startStunTest" -> handleStartStunTest(call, result)
            "stopStunTest" -> { cancelStunTest(); result.success(null) }
            "startNetworkQualityTest" -> handleStartNetworkQualityTest(result)
            "stopNetworkQualityTest" -> { cancelNetworkQualityTest(); result.success(null) }

            else -> result.notImplemented()
        }
    }

    // ── Handler implementations ────────────────────────────────────────────

    private fun handleInitialize(call: MethodCall, result: MethodChannel.Result) {
        val ctx = appContext ?: return result.error("NO_CONTEXT", "Plugin not attached to engine", null)
        val map = call.arguments as? Map<*, *> ?: return result.error("BAD_ARGS", "Expected map", null)

        try {
            val basePath = map["basePath"] as? String ?: ctx.filesDir.absolutePath
            SingboxEngine.setup(
                context = ctx,
                base = basePath,
                working = map["workingPath"] as? String ?: "${ctx.filesDir}/working",
                temp = map["tempPath"] as? String ?: ctx.cacheDir.absolutePath,
                port = (map["commandServerPort"] as? Int) ?: 10086,
                secret = map["commandServerSecret"] as? String ?: "",
            )
            manager.tryConnectToRunningService()
            result.success(null)
        } catch (e: Exception) {
            result.error("INIT_ERROR", e.message, e.stackTraceToString())
        }
    }

    private fun handleConnect(call: MethodCall, result: MethodChannel.Result) {
        val map = call.arguments as? Map<*, *> ?: return result.error("BAD_ARGS", "Expected map", null)
        scope.launch {
            val options = SessionOptions.fromMap(map)
            val r = manager.connectAwait(options)
            if (r.isSuccess) result.success(null)
            else result.error("CONNECT_FAILED", r.exceptionOrNull()?.message, null)
        }
    }

    private fun handleRequestVpnPermission(result: MethodChannel.Result) {
        val act = activity ?: return result.success(false)
        val intent = VpnService.prepare(act)
        if (intent == null) {
            result.success(true)
        } else {
            vpnPermissionResult = result
            act.startActivityForResult(intent, VPN_PERMISSION_REQUEST)
        }
    }

    private fun handleCheckConfig(call: MethodCall, result: MethodChannel.Result) {
        val content = call.argument<String>("content") ?: return result.error("BAD_ARGS", "Missing content", null)
        val check = SingboxEngine.checkConfig(content)
        if (check.isSuccess) {
            result.success(null)
        } else {
            result.error("INVALID_CONFIG", check.exceptionOrNull()?.message ?: "Configuration validation failed", null)
        }
    }

    private fun handleFormatConfig(call: MethodCall, result: MethodChannel.Result) {
        val content = call.argument<String>("content") ?: return result.error("BAD_ARGS", "Missing content", null)
        SingboxEngine.formatConfig(content)
            .onSuccess { result.success(it) }
            .onFailure { result.error("FORMAT_ERROR", it.message, null) }
    }

    private fun handleSelectOutbound(call: MethodCall, result: MethodChannel.Result) {
        val groupTag = call.argument<String>("groupTag") ?: return result.error("BAD_ARGS", "Missing groupTag", null)
        val outboundTag = call.argument<String>("outboundTag") ?: return result.error("BAD_ARGS", "Missing outboundTag", null)
        manager.selectOutbound(groupTag, outboundTag)
        result.success(null)
    }

    private fun handleUrlTest(call: MethodCall, result: MethodChannel.Result) {
        val groupTag = call.argument<String>("groupTag") ?: return result.error("BAD_ARGS", "Missing groupTag", null)
        manager.urlTest(groupTag)
        result.success(null)
    }

    private fun handleStartStunTest(call: MethodCall, result: MethodChannel.Result) {
        val server = call.argument<String>("server")?.takeIf { it.isNotBlank() } ?: Libbox.STUNDefaultServer

        val handler = object : STUNTestHandler {
            override fun onProgress(progress: STUNTestProgress?) {
                progress ?: return
                scope.launch {
                    stunSink?.success(mapOf(
                        "isRunning" to true,
                        "phase" to phaseToString(progress.phase),
                        "externalAddress" to progress.externalAddr,
                        "latencyMs" to progress.latencyMs.toInt(),
                        "natMapping" to if (progress.natMapping > 0) Libbox.formatNATMapping(progress.natMapping) else "",
                        "natFiltering" to if (progress.natFiltering > 0) Libbox.formatNATFiltering(progress.natFiltering) else "",
                        "natTypeSupported" to false,
                    ))
                }
            }
            override fun onResult(r: io.nekohasekai.libbox.STUNTestResult?) {
                r ?: return
                scope.launch {
                    stunSink?.success(mapOf(
                        "isRunning" to false,
                        "phase" to "done",
                        "externalAddress" to r.externalAddr,
                        "latencyMs" to r.latencyMs.toInt(),
                        "natMapping" to Libbox.formatNATMapping(r.natMapping),
                        "natFiltering" to Libbox.formatNATFiltering(r.natFiltering),
                        "natTypeSupported" to r.natTypeSupported,
                    ))
                    stunTest = null
                    stunJob = null
                }
            }
            override fun onError(message: String?) {
                scope.launch {
                    stunSink?.error("STUN_FAILED", message ?: "STUN test failed", null)
                    stunTest = null
                    stunJob = null
                }
            }
        }

        if (SingboxVPNService.instance != null || SingboxProxyService.instance != null) {
            stunJob = scope.launch(Dispatchers.IO) {
                try {
                    Libbox.newStandaloneCommandClient().startSTUNTest(server, "", handler)
                } catch (e: Exception) {
                    withContext(Dispatchers.Main) {
                        stunSink?.error("STUN_FAILED", e.message, null)
                        stunJob = null
                    }
                }
            }
        } else {
            val test = Libbox.newSTUNTest()
            stunTest = test
            scope.launch(Dispatchers.IO) {
                test.start(server, handler)
            }
        }
        result.success(null)
    }

    private fun cancelStunTest() {
        stunJob?.cancel()
        stunJob = null
        stunTest?.cancel()
        stunTest = null
    }

    private fun phaseToString(phase: Int): String = when (phase) {
        Libbox.STUNPhaseBinding.toInt() -> "binding"
        Libbox.STUNPhaseNATMapping.toInt() -> "nat_mapping"
        Libbox.STUNPhaseNATFiltering.toInt() -> "nat_filtering"
        Libbox.STUNPhaseDone.toInt() -> "done"
        else -> "unknown"
    }

    private fun handleStartNetworkQualityTest(result: MethodChannel.Result) {
        val handler = object : NetworkQualityTestHandler {
            override fun onProgress(progress: NetworkQualityProgress?) {
                progress ?: return
                scope.launch {
                    networkQualitySink?.success(mapOf(
                        "isRunning" to true,
                        "idleLatencyMs" to progress.idleLatencyMs.toInt(),
                        "downloadCapacityBps" to progress.downloadCapacity,
                        "uploadCapacityBps" to progress.uploadCapacity,
                        "downloadRPM" to progress.downloadRPM.toInt(),
                        "uploadRPM" to progress.uploadRPM.toInt(),
                    ))
                }
            }
            override fun onResult(r: io.nekohasekai.libbox.NetworkQualityResult?) {
                r ?: return
                scope.launch {
                    networkQualitySink?.success(mapOf(
                        "isRunning" to false,
                        "idleLatencyMs" to r.idleLatencyMs.toInt(),
                        "downloadCapacityBps" to r.downloadCapacity,
                        "uploadCapacityBps" to r.uploadCapacity,
                        "downloadRPM" to r.downloadRPM.toInt(),
                        "uploadRPM" to r.uploadRPM.toInt(),
                    ))
                    networkQualityTest = null
                    networkQualityJob = null
                }
            }
            override fun onError(message: String?) {
                scope.launch {
                    networkQualitySink?.error("QUALITY_FAILED", message ?: "Network quality test failed", null)
                    networkQualityTest = null
                    networkQualityJob = null
                }
            }
        }

        if (SingboxVPNService.instance != null || SingboxProxyService.instance != null) {
            networkQualityJob = scope.launch(Dispatchers.IO) {
                try {
                    Libbox.newStandaloneCommandClient()
                        .startNetworkQualityTest(Libbox.NetworkQualityDefaultConfigURL, "", false, 30, false, handler)
                } catch (e: Exception) {
                    withContext(Dispatchers.Main) {
                        networkQualitySink?.error("QUALITY_FAILED", e.message, null)
                        networkQualityJob = null
                    }
                }
            }
        } else {
            val test = Libbox.newNetworkQualityTest()
            networkQualityTest = test
            scope.launch(Dispatchers.IO) {
                test.start(Libbox.NetworkQualityDefaultConfigURL, false, 30, false, handler)
            }
        }
        result.success(null)
    }

    private fun cancelNetworkQualityTest() {
        networkQualityJob?.cancel()
        networkQualityJob = null
        networkQualityTest?.cancel()
        networkQualityTest = null
    }

    // ── FlutterPlugin ──────────────────────────────────────────────────────

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        stateEventChannel.setStreamHandler(null)
        trafficEventChannel.setStreamHandler(null)
        coreLogEventChannel.setStreamHandler(null)
        connectionEventChannel.setStreamHandler(null)
        groupEventChannel.setStreamHandler(null)
        clashModeEventChannel.setStreamHandler(null)
        clashModesEventChannel.setStreamHandler(null)
        faultEventChannel.setStreamHandler(null)
        networkQualityEventChannel.setStreamHandler(null)
        stunEventChannel.setStreamHandler(null)
        cancelNetworkQualityTest()
        cancelStunTest()
        scope.cancel()
        manager.dispose()
        appContext = null
    }

    // ── ActivityAware ──────────────────────────────────────────────────────

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() { activity = null }
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivity() { activity = null }

    // ── ActivityResultListener ─────────────────────────────────────────────

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode == VPN_PERMISSION_REQUEST) {
            vpnPermissionResult?.success(resultCode == Activity.RESULT_OK)
            vpnPermissionResult = null
            return true
        }
        return false
    }
}
