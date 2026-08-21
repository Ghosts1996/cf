package dev.amirzr.singbox

object SingboxConstants {
    const val CHANNEL = "flutter_singbox_client"
    const val STATE_CHANNEL = "flutter_singbox_client/state"
    const val TRAFFIC_CHANNEL = "flutter_singbox_client/traffic"
    const val LOG_CHANNEL = "flutter_singbox_client/logs"
    const val CONNECTION_CHANNEL = "flutter_singbox_client/connections"
    const val GROUP_CHANNEL = "flutter_singbox_client/groups"
    const val CLASH_MODE_CHANNEL = "flutter_singbox_client/clash_mode"
    const val CLASH_MODES_CHANNEL = "flutter_singbox_client/clash_modes"
    const val ALERT_CHANNEL = "flutter_singbox_client/alerts"
    const val NETWORK_QUALITY_CHANNEL = "flutter_singbox_client/network_quality"
    const val STUN_CHANNEL = "flutter_singbox_client/stun"

    const val NOTIFICATION_CHANNEL_ID = "singbox_service"
    const val NOTIFICATION_ID = 1001

    const val PLUGIN_VERSION = "1.1.0"

    const val STATE_STOPPED = 0
    const val STATE_STARTING = 1
    const val STATE_STARTED = 2
    const val STATE_STOPPING = 3

    // NetworkMode values — mirror Dart NetworkMode enum
    const val MODE_VPN = "vpn"
    const val MODE_PROXY = "proxy"
}
