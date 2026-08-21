package dev.amirzr.singbox.settings

/**
 * Resolved notification configuration. All fields carry a default so the SDK
 * is fully functional without any developer-provided values.
 */
data class NotificationConfig(
    val channelName: String,
    val title: String,
    val showTrafficStats: Boolean,
    val showStopButton: Boolean,
    val stopButtonLabel: String,
) {
    companion object {
        val DEFAULT = NotificationConfig(
            channelName = "VPN Service",
            title = "Singbox",
            showTrafficStats = false,
            showStopButton = false,
            stopButtonLabel = "Stop",
        )

        fun fromMap(map: Map<*, *>?): NotificationConfig {
            if (map == null) return DEFAULT
            return NotificationConfig(
                channelName = map["channelName"] as? String ?: DEFAULT.channelName,
                title = map["title"] as? String ?: DEFAULT.title,
                showTrafficStats = map["showTrafficStats"] as? Boolean ?: DEFAULT.showTrafficStats,
                showStopButton = map["showStopButton"] as? Boolean ?: DEFAULT.showStopButton,
                stopButtonLabel = map["stopButtonLabel"] as? String ?: DEFAULT.stopButtonLabel,
            )
        }
    }

    fun toMap(): Map<String, Any?> = mapOf(
        "channelName" to channelName,
        "title" to title,
        "showTrafficStats" to showTrafficStats,
        "showStopButton" to showStopButton,
        "stopButtonLabel" to stopButtonLabel,
    )
}
