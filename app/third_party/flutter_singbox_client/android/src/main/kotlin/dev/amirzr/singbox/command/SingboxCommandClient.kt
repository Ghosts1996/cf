package dev.amirzr.singbox.command

import android.util.Log
import io.nekohasekai.libbox.*
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * Wraps a single libbox CommandClient that subscribes to all event types:
 * Status, Log, Groups, ClashMode, Connections.
 */
class SingboxCommandClient(
    private val handler: Handler,
) {
    companion object {
        private const val TAG = "SingboxCommandClient"
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private var client: CommandClient? = null

    @Volatile private var lastStats: Map<String, Any> = emptyMap()

    interface Handler {
        fun onConnected()
        fun onDisconnected(message: String)
        fun onStatus(stats: Map<String, Any>)
        fun onLogs(entries: List<Map<String, Any>>)
        fun onGroups(groups: List<Map<String, Any>>)
        fun onConnections(conns: List<Map<String, Any>>)
        fun onClashModes(modes: List<String>, current: String)
        fun onClashModeChanged(mode: String)
        fun onAlert(message: String)
    }

    fun connect() {
        scope.launch {
            val opts = CommandClientOptions()
            opts.addCommand(Libbox.CommandStatus)
            opts.addCommand(Libbox.CommandLog)
            opts.addCommand(Libbox.CommandGroup)
            opts.addCommand(Libbox.CommandClashMode)
            opts.addCommand(Libbox.CommandConnections)
            opts.statusInterval = 1_000_000_000L

            // Retry until the CommandServer is ready (it starts asynchronously in the service)
            var attempt = 0
            while (isActive) {
                try {
                    val c = CommandClient(clientHandler, opts)
                    c.connect()
                    client = c
                    return@launch
                } catch (e: Exception) {
                    attempt++
                    if (attempt >= 20) { // give up after ~10 seconds
                        Log.e(TAG, "connect failed after $attempt attempts", e)
                        handler.onDisconnected(e.message ?: "connection error")
                        return@launch
                    }
                    Log.d(TAG, "connect attempt $attempt failed, retrying in 500ms…")
                    delay(500)
                }
            }
        }
    }

    fun disconnect() {
        scope.cancel()
        runCatching { client?.disconnect() }
        client = null
        lastStats = emptyMap()
    }

    // ── Commands ───────────────────────────────────────────────────────────

    fun selectOutbound(groupTag: String, outboundTag: String) =
        scope.launch { runCatching { client?.selectOutbound(groupTag, outboundTag) } }

    fun urlTest(groupTag: String) =
        scope.launch { runCatching { client?.urlTest(groupTag) } }

    fun setClashMode(mode: String) =
        scope.launch { runCatching { client?.setClashMode(mode) } }

    fun closeConnection(id: String) =
        scope.launch { runCatching { client?.closeConnection(id) } }

    fun closeAllConnections() =
        scope.launch { runCatching { client?.closeConnections() } }

    fun serviceReload() =
        scope.launch { runCatching { client?.serviceReload() } }

    fun getSystemProxyStatus(): Map<String, Any> = try {
        val s = client?.systemProxyStatus
        if (s != null) mapOf("available" to s.available, "enabled" to s.enabled)
        else mapOf("available" to false, "enabled" to false)
    } catch (_: Exception) {
        mapOf("available" to false, "enabled" to false)
    }

    fun setSystemProxyEnabled(enabled: Boolean) =
        scope.launch { runCatching { client?.setSystemProxyEnabled(enabled) } }

    fun getLastStats(): Map<String, Any> = lastStats

    // ── CommandClientHandler ───────────────────────────────────────────────

    private val clientHandler = object : CommandClientHandler {

        override fun connected() = handler.onConnected()

        override fun disconnected(message: String?) =
            handler.onDisconnected(message ?: "")

        override fun writeStatus(message: StatusMessage?) {
            message ?: return
            val stats = mapOf<String, Any>(
                "uplinkBps" to message.uplink,
                "downlinkBps" to message.downlink,
                "uplinkTotalBytes" to message.uplinkTotal,
                "downlinkTotalBytes" to message.downlinkTotal,
                "memoryBytes" to message.memory,
                "goroutines" to message.goroutines,
                "connectionsIn" to message.connectionsIn,
                "connectionsOut" to message.connectionsOut,
            )
            lastStats = stats
            handler.onStatus(stats)
        }

        override fun writeLogs(messageList: LogIterator?) {
            messageList ?: return
            val entries = mutableListOf<Map<String, Any>>()
            while (messageList.hasNext()) {
                val entry = messageList.next() ?: continue
                entries.add(mapOf(
                    "level" to logLevelName(entry.level.toInt()),
                    "message" to (entry.message ?: ""),
                    "time" to System.currentTimeMillis(),
                ))
            }
            if (entries.isNotEmpty()) handler.onLogs(entries)
        }

        override fun writeGroups(message: OutboundGroupIterator?) {
            message ?: return
            val groups = mutableListOf<Map<String, Any>>()
            while (message.hasNext()) {
                val g = message.next() ?: continue
                val items = mutableListOf<Map<String, Any>>()
                val itemIter = g.items
                if (itemIter != null) {
                    while (itemIter.hasNext()) {
                        val item = itemIter.next() ?: continue
                        items.add(mapOf(
                            "tag" to (item.tag ?: ""),
                            "type" to (item.type ?: ""),
                            "urlTestDelayMs" to item.urlTestDelay,
                            "urlTestTime" to item.urlTestTime,
                        ))
                    }
                }
                groups.add(mapOf(
                    "tag" to (g.tag ?: ""),
                    "type" to (g.type ?: ""),
                    "selectable" to g.selectable,
                    "selected" to (g.selected ?: ""),
                    "isExpand" to g.isExpand,
                    "items" to items,
                ))
            }
            handler.onGroups(groups)
        }

        override fun writeOutbounds(message: OutboundGroupItemIterator?) {}

        override fun initializeClashMode(modeList: StringIterator?, currentMode: String?) {
            val modes = mutableListOf<String>()
            if (modeList != null) {
                while (modeList.hasNext()) modes.add(modeList.next() ?: continue)
            }
            handler.onClashModes(modes, currentMode ?: "")
        }

        override fun updateClashMode(newMode: String?) {
            newMode?.let { handler.onClashModeChanged(it) }
        }

        override fun setDefaultLogLevel(level: Int) {}

        override fun clearLogs() {}

        override fun writeConnectionEvents(events: ConnectionEvents?) {
            events ?: return
            val conns = mutableListOf<Map<String, Any>>()
            val iter = events.iterator() ?: return
            while (iter.hasNext()) {
                val ev = iter.next() ?: continue
                val c = ev.connection
                if (c != null) {
                    // New or updated connection — full data
                    val chainStr = buildString {
                        val chainIter = runCatching { c.chain() }.getOrNull()
                        if (chainIter != null) {
                            while (chainIter.hasNext()) {
                                if (isNotEmpty()) append(" → ")
                                append(chainIter.next() ?: continue)
                            }
                        }
                    }
                    val map = mutableMapOf<String, Any>(
                        "id" to (c.id ?: ""),
                        "inbound" to (c.inbound ?: ""),
                        "inboundType" to (c.inboundType ?: ""),
                        "ipVersion" to c.ipVersion.toInt(),
                        "network" to (c.network ?: ""),
                        "source" to (c.source ?: ""),
                        "destination" to (c.destination ?: ""),
                        "domain" to (c.domain ?: ""),
                        "protocol" to (c.protocol ?: ""),
                        "outbound" to (c.outbound ?: ""),
                        "outboundType" to (c.outboundType ?: ""),
                        "createdAt" to c.createdAt,
                        "uplinkTotalBytes" to c.uplinkTotal,
                        "downlinkTotalBytes" to c.downlinkTotal,
                        "rule" to (c.rule ?: ""),
                        "chain" to chainStr,
                    )
                    if (c.closedAt != 0L) map["closedAt"] = c.closedAt
                    conns.add(map)
                } else if (ev.id?.isNotEmpty() == true && ev.closedAt != 0L) {
                    // Close-only event — just id + closedAt + traffic deltas
                    conns.add(mapOf(
                        "id" to ev.id!!,
                        "closedAt" to ev.closedAt,
                        "uplinkTotalBytes" to ev.uplinkDelta,
                        "downlinkTotalBytes" to ev.downlinkDelta,
                    ))
                }
            }
            if (conns.isNotEmpty()) handler.onConnections(conns)
        }
    }

    private fun logLevelName(level: Int): String = when (level) {
        0 -> "trace"
        1 -> "debug"
        2 -> "info"
        3 -> "warn"
        4 -> "error"
        5 -> "fatal"
        6 -> "panic"
        else -> "info"
    }
}
