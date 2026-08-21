package dev.amirzr.singbox.service

import dev.amirzr.singbox.SingboxConstants
import dev.amirzr.singbox.settings.MemoryLimitConfig
import dev.amirzr.singbox.settings.NotificationConfig
import org.json.JSONArray
import org.json.JSONObject

/**
 * All data required to connect the VPN/proxy service, passed from the host app
 * at call time. Nothing is stored in the SDK between calls.
 */
data class SessionOptions(
    val config: String,
    val networkMode: String = SingboxConstants.MODE_VPN,
    val allowBypass: Boolean = false,
    val systemProxyEnabled: Boolean = false,
    val perAppProxyEnabled: Boolean = false,
    val perAppProxyMode: String = "exclude",  // "include" or "exclude"
    val perAppProxyList: List<String> = emptyList(),
    val notification: NotificationConfig = NotificationConfig.DEFAULT,
    val memoryLimit: MemoryLimitConfig = MemoryLimitConfig.DEFAULT,
    val killSwitch: Boolean = false,
) {
    companion object {
        const val EXTRA_KEY = "service_start_config_json"

        /** Recursively converts JSONObject/JSONArray into Map/List so nested
         *  values survive the intent JSON round-trip. */
        fun jsonObjectToMap(obj: JSONObject): Map<String, Any?> {
            val map = mutableMapOf<String, Any?>()
            for (key in obj.keys()) {
                map[key] = when (val v = obj.get(key)) {
                    is JSONObject -> jsonObjectToMap(v)
                    is JSONArray  -> jsonArrayToList(v)
                    JSONObject.NULL -> null
                    else -> v
                }
            }
            return map
        }

        private fun jsonArrayToList(arr: JSONArray): List<Any?> =
            (0 until arr.length()).map { i ->
                when (val v = arr.get(i)) {
                    is JSONObject -> jsonObjectToMap(v)
                    is JSONArray  -> jsonArrayToList(v)
                    JSONObject.NULL -> null
                    else -> v
                }
            }

        @Suppress("UNCHECKED_CAST")
        fun fromMap(map: Map<*, *>): SessionOptions {
            val notifMap = map["notification"] as? Map<*, *>
            val perAppList = (map["perAppProxyList"] as? List<*>)
                ?.filterIsInstance<String>() ?: emptyList()
            return SessionOptions(
                config = map["config"] as? String ?: "",
                networkMode = map["networkMode"] as? String ?: SingboxConstants.MODE_VPN,
                allowBypass = map["allowBypass"] as? Boolean ?: false,
                systemProxyEnabled = map["systemProxyEnabled"] as? Boolean ?: false,
                perAppProxyEnabled = map["perAppProxyEnabled"] as? Boolean ?: false,
                perAppProxyMode = map["perAppProxyMode"] as? String ?: "exclude",
                perAppProxyList = perAppList,
                notification = NotificationConfig.fromMap(notifMap),
                memoryLimit = MemoryLimitConfig.fromMap(map),
                killSwitch = map["killSwitch"] as? Boolean ?: false,
            )
        }
    }

    fun toMap(): Map<String, Any?> = mapOf(
        "config" to config,
        "networkMode" to networkMode,
        "allowBypass" to allowBypass,
        "systemProxyEnabled" to systemProxyEnabled,
        "perAppProxyEnabled" to perAppProxyEnabled,
        "perAppProxyMode" to perAppProxyMode,
        "perAppProxyList" to perAppProxyList,
        "notification" to notification.toMap(),
        "killSwitch" to killSwitch,
    ) + memoryLimit.toMap()
}
