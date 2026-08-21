package dev.amirzr.singbox.engine

import android.content.Context
import android.util.Log
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.SetupOptions
import java.io.File

/**
 * Thin wrapper around the Libbox JNI layer.
 * Handles one-time global initialisation via Libbox.setup().
 */
object SingboxEngine {

    private const val TAG = "SingboxEngine"

    @Volatile private var _initialized = false

    var basePath = ""; private set
    var workingPath = ""; private set
    var tempPath = ""; private set
    var serverPort = 10086; private set
    var serverSecret = ""; private set
    private var debugMode = false
    private var maxLines = 3000

    fun setup(
        context: Context,
        base: String,
        working: String,
        temp: String,
        port: Int = 10086,
        secret: String = "",
        maxLines: Int = 3000,
        debugMode: Boolean = false,
        oomEnabled: Boolean = true,
        oomLimitMB: Int = 50,
    ) {
        basePath = base
        workingPath = working
        tempPath = temp
        serverPort = port
        serverSecret = secret
        this.debugMode = debugMode
        this.maxLines = maxLines

        listOf(base, working, temp).forEach { File(it).mkdirs() }

        try {
            val options = buildSetupOptions(
                oomEnabled = oomEnabled,
                oomLimitMB = oomLimitMB,
            )

            if (_initialized) {
                Libbox.reloadSetupOptions(options)
            } else {
                Libbox.setup(options)
                runCatching {
                    Libbox.setLocale(
                        context.resources.configuration.locales[0].toLanguageTag()
                    )
                }
                _initialized = true
            }
            Log.i(TAG, "Sing-box engine ready — core ${Libbox.version()}")
        } catch (e: Exception) {
            Log.e(TAG, "Engine setup failed", e)
            throw e
        }
    }

    /**
     * Initialises the engine with default filesystem paths if not already done.
     * Called by services that may start before Flutter runs (e.g. after device reboot).
     */
    fun ensureInitialized(context: Context) {
        if (_initialized) return
        runCatching {
            val base = context.filesDir.absolutePath
            setup(
                context = context,
                base = base,
                working = "$base/working",
                temp = context.cacheDir.absolutePath,
            )
        }
    }

    fun updateMemorySettings(enabled: Boolean, limitMb: Int, killConnections: Boolean) {
        if (!_initialized) return
        try {
            Libbox.reloadSetupOptions(buildSetupOptions(
                oomEnabled = enabled,
                oomLimitMB = limitMb,
                oomKillConnections = killConnections,
            ))
        } catch (e: Exception) {
            Log.e(TAG, "Failed to reload memory settings", e)
        }
    }

    private fun buildSetupOptions(
        oomEnabled: Boolean = true,
        oomLimitMB: Int = 50,
        oomKillConnections: Boolean = false,
    ): SetupOptions {
        val opts = SetupOptions()
        opts.basePath = basePath
        opts.workingPath = workingPath
        opts.tempPath = tempPath
        opts.fixAndroidStack = true
        opts.debug = debugMode
        opts.commandServerListenPort = serverPort
        opts.commandServerSecret = serverSecret
        opts.logMaxLines = maxLines.toLong()
        opts.oomKillerEnabled = oomEnabled
        opts.oomMemoryLimit = oomLimitMB.toLong() * 1024L * 1024L
        // oomKillerDisabled == true means "do NOT drop connections when limit is hit"
        opts.oomKillerDisabled = !oomKillConnections
        return opts
    }

    fun checkConfig(content: String): Result<Unit> = runCatching {
        Libbox.checkConfig(content)
    }

    fun formatConfig(content: String): Result<String> = runCatching {
        Libbox.formatConfig(content)?.value ?: content
    }

    fun version(): String = runCatching { Libbox.version() }.getOrDefault("unknown")
    fun goVersion(): String = runCatching { Libbox.goVersion() }.getOrDefault("unknown")
}
