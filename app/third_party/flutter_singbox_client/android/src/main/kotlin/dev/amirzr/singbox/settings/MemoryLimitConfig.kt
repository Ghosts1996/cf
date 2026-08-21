package dev.amirzr.singbox.settings

/**
 * Go runtime soft memory cap configuration. Applied before service start via
 * Libbox.reloadSetupOptions(). This is not a JVM heap limit.
 */
data class MemoryLimitConfig(
    val enabled: Boolean,
    val limitMb: Int,
    val killConnections: Boolean,
) {
    companion object {
        val DEFAULT = MemoryLimitConfig(
            enabled = false,
            limitMb = 50,
            killConnections = false,
        )

        fun fromMap(map: Map<*, *>?): MemoryLimitConfig {
            if (map == null) return DEFAULT
            return MemoryLimitConfig(
                enabled = map["enableMemoryLimit"] as? Boolean ?: DEFAULT.enabled,
                limitMb = (map["memoryLimitMb"] as? Number)?.toInt() ?: DEFAULT.limitMb,
                killConnections = map["killConnectionsOnLimit"] as? Boolean ?: DEFAULT.killConnections,
            )
        }
    }

    fun toMap(): Map<String, Any?> = mapOf(
        "enableMemoryLimit" to enabled,
        "memoryLimitMb" to limitMb,
        "killConnectionsOnLimit" to killConnections,
    )
}
