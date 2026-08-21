package dev.amirzr.singbox.platform

import android.net.ConnectivityManager
import android.net.DnsResolver
import android.os.Build
import android.os.CancellationSignal
import android.system.ErrnoException
import android.util.Log
import io.nekohasekai.libbox.ExchangeContext
import io.nekohasekai.libbox.LocalDNSTransport
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.asExecutor
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.suspendCancellableCoroutine
import java.net.InetAddress
import java.net.UnknownHostException
import kotlin.coroutines.resume

class LocalDNSTransportImpl(
    private val connectivityManager: ConnectivityManager,
) : LocalDNSTransport {

    companion object {
        private const val TAG = "LocalDNSTransport"
    }

    override fun raw(): Boolean = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q

    override fun lookup(ctx: ExchangeContext, network: String, domain: String) {
        val activeNetwork = connectivityManager.activeNetwork
        runBlocking {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && activeNetwork != null) {
                lookupQ(ctx, network, domain, activeNetwork)
            } else {
                try {
                    val addrs = InetAddress.getAllByName(domain)
                    ctx.success(addrs.mapNotNull { it.hostAddress }.joinToString("\n"))
                } catch (e: UnknownHostException) {
                    ctx.errorCode(3) // NXDOMAIN
                } catch (e: Exception) {
                    Log.w(TAG, "lookup fallback failed for $domain", e)
                    ctx.errorCode(2) // SERVFAIL
                }
            }
        }
    }

    @androidx.annotation.RequiresApi(Build.VERSION_CODES.Q)
    private suspend fun lookupQ(
        ctx: ExchangeContext,
        network: String,
        domain: String,
        activeNetwork: android.net.Network,
    ) {
        suspendCancellableCoroutine { cont ->
            val signal = CancellationSignal()
            cont.invokeOnCancellation { signal.cancel() }
            ctx.onCancel { signal.cancel() }
            val callback = object : DnsResolver.Callback<Collection<InetAddress>> {
                override fun onAnswer(answer: Collection<InetAddress>, rcode: Int) {
                    if (rcode == 0) {
                        ctx.success(answer.mapNotNull { it.hostAddress }.joinToString("\n"))
                    } else {
                        ctx.errorCode(rcode)
                    }
                    cont.resume(Unit)
                }

                override fun onError(error: DnsResolver.DnsException) {
                    val cause = error.cause
                    if (cause is ErrnoException) {
                        ctx.errnoCode(cause.errno)
                        cont.resume(Unit)
                        return
                    }
                    ctx.errorCode(2) // SERVFAIL
                    cont.resume(Unit)
                }
            }
            val type = when {
                network.endsWith("4") -> DnsResolver.TYPE_A
                network.endsWith("6") -> DnsResolver.TYPE_AAAA
                else -> null
            }
            if (type != null) {
                DnsResolver.getInstance().query(
                    activeNetwork, domain, type,
                    DnsResolver.FLAG_NO_RETRY, Dispatchers.IO.asExecutor(), signal, callback,
                )
            } else {
                DnsResolver.getInstance().query(
                    activeNetwork, domain,
                    DnsResolver.FLAG_NO_RETRY, Dispatchers.IO.asExecutor(), signal, callback,
                )
            }
        }
    }

    @androidx.annotation.RequiresApi(Build.VERSION_CODES.Q)
    override fun exchange(ctx: ExchangeContext, message: ByteArray) {
        val activeNetwork = connectivityManager.activeNetwork ?: run {
            ctx.errorCode(2)
            return
        }
        runBlocking {
            suspendCancellableCoroutine { cont ->
                val signal = CancellationSignal()
                cont.invokeOnCancellation { signal.cancel() }
                ctx.onCancel { signal.cancel() }
                val callback = object : DnsResolver.Callback<ByteArray> {
                    override fun onAnswer(answer: ByteArray, rcode: Int) {
                        if (rcode == 0) ctx.rawSuccess(answer) else ctx.errorCode(rcode)
                        cont.resume(Unit)
                    }

                    override fun onError(error: DnsResolver.DnsException) {
                        val cause = error.cause
                        if (cause is ErrnoException) {
                            ctx.errnoCode(cause.errno)
                        } else {
                            ctx.errorCode(2)
                        }
                        cont.resume(Unit)
                    }
                }
                DnsResolver.getInstance().rawQuery(
                    activeNetwork, message,
                    DnsResolver.FLAG_NO_RETRY, Dispatchers.IO.asExecutor(), signal, callback,
                )
            }
        }
    }
}
