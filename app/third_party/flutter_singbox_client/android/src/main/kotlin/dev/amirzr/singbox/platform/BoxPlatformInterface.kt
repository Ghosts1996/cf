package dev.amirzr.singbox.platform

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.system.OsConstants
import android.util.Log
import androidx.annotation.RequiresApi
import io.nekohasekai.libbox.*
import java.net.InetSocketAddress
import java.net.NetworkInterface as JNetworkInterface
import io.nekohasekai.libbox.NetworkInterface as LibboxNetworkInterface

/**
 * Default PlatformInterface implementations shared by VPN and Proxy services.
 * Override openTun() and autoDetectInterfaceControl() in VPN service.
 */
interface BoxPlatformInterface : PlatformInterface {

    val boxContext: Context
    val boxConnectivityManager: ConnectivityManager

    override fun usePlatformAutoDetectInterfaceControl(): Boolean = true

    override fun autoDetectInterfaceControl(fd: Int) {}

    override fun openTun(options: TunOptions): Int = -1

    override fun useProcFS(): Boolean = Build.VERSION.SDK_INT < Build.VERSION_CODES.Q

    @RequiresApi(Build.VERSION_CODES.Q)
    override fun findConnectionOwner(
        ipProtocol: Int,
        sourceAddress: String,
        sourcePort: Int,
        destinationAddress: String,
        destinationPort: Int,
    ): ConnectionOwner {
        return try {
            val uid = boxConnectivityManager.getConnectionOwnerUid(
                ipProtocol,
                InetSocketAddress(sourceAddress, sourcePort),
                InetSocketAddress(destinationAddress, destinationPort),
            )
            val packages = boxContext.packageManager.getPackagesForUid(uid)
            val owner = ConnectionOwner()
            owner.userId = uid
            owner.userName = packages?.firstOrNull() ?: ""
            owner.setAndroidPackageNames(StringListIterator(packages?.toList() ?: emptyList()))
            owner
        } catch (e: Exception) {
            ConnectionOwner()
        }
    }

    override fun getInterfaces(): NetworkInterfaceIterator {
        val ifaces = mutableListOf<LibboxNetworkInterface>()
        try {
            for (network in boxConnectivityManager.allNetworks) {
                val lp = boxConnectivityManager.getLinkProperties(network) ?: continue
                val name = lp.interfaceName ?: continue
                val jni = runCatching { JNetworkInterface.getByName(name) }.getOrNull() ?: continue
                val ni = LibboxNetworkInterface()
                ni.name = name
                ni.index = jni.index
                val caps = boxConnectivityManager.getNetworkCapabilities(network)
                if (caps != null) {
                    ni.type = when {
                        caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> Libbox.InterfaceTypeWIFI
                        caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> Libbox.InterfaceTypeCellular
                        caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> Libbox.InterfaceTypeEthernet
                        else -> Libbox.InterfaceTypeOther
                    }
                    // Go's UpdateInterfaces() filters out any interface where flags & FlagUp == 0.
                    // Set IFF_UP | IFF_RUNNING for internet-capable interfaces so they pass the filter.
                    var flags = 0
                    if (caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) {
                        flags = flags or OsConstants.IFF_UP or OsConstants.IFF_RUNNING
                    }
                    if (jni.isLoopback) flags = flags or OsConstants.IFF_LOOPBACK
                    if (jni.isPointToPoint) flags = flags or OsConstants.IFF_POINTOPOINT
                    if (jni.supportsMulticast()) flags = flags or OsConstants.IFF_MULTICAST
                    ni.flags = flags
                }
                ifaces.add(ni)
            }
        } catch (e: Exception) {
            Log.w("BoxPlatformInterface", "getInterfaces error", e)
        }
        return NetworkInterfaceListIterator(ifaces)
    }

    @Suppress("DEPRECATION")
    override fun readWIFIState(): WIFIState? {
        // WifiManager.connectionInfo is deprecated on API 31+ in favour of
        // WifiManager.NetworkCallback, but the Go core only reads SSID/BSSID so
        // the legacy path is sufficient here. Replace if min SDK is raised to 31+.
        return try {
            val wm = boxContext.getSystemService(Context.WIFI_SERVICE) as? android.net.wifi.WifiManager
            val info = wm?.connectionInfo ?: return null
            var ssid = info.ssid ?: return null
            if (ssid == "<unknown ssid>") return WIFIState("", "")
            if (ssid.startsWith("\"") && ssid.endsWith("\"")) ssid = ssid.substring(1, ssid.length - 1)
            WIFIState(ssid, info.bssid ?: "")
        } catch (_: Exception) {
            null
        }
    }

    override fun localDNSTransport(): LocalDNSTransport? =
        LocalDNSTransportImpl(boxConnectivityManager)

    override fun systemCertificates(): StringIterator = EmptyStringIterator()

    override fun clearDNSCache() {}

    override fun underNetworkExtension(): Boolean = false

    override fun includeAllNetworks(): Boolean = false

    override fun startNeighborMonitor(listener: NeighborUpdateListener?) {}

    override fun closeNeighborMonitor(listener: NeighborUpdateListener?) {}

    override fun registerMyInterface(name: String?) {}

    override fun sendNotification(notification: Notification) {}
}

// ── Iterator helpers ───────────────────────────────────────────────────────

class StringListIterator(list: List<String>) : StringIterator {
    private val iter = list.iterator()
    override fun len(): Int = 0
    override fun hasNext(): Boolean = iter.hasNext()
    override fun next(): String = iter.next()
}

private class EmptyStringIterator : StringIterator {
    override fun len(): Int = 0
    override fun hasNext(): Boolean = false
    override fun next(): String = ""
}

private class NetworkInterfaceListIterator(
    private val list: List<LibboxNetworkInterface>,
) : NetworkInterfaceIterator {
    private var i = 0
    override fun hasNext(): Boolean = i < list.size
    override fun next(): LibboxNetworkInterface = list[i++]
}
