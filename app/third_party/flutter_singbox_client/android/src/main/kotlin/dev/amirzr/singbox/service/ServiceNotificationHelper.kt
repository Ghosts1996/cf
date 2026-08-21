package dev.amirzr.singbox.service

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import dev.amirzr.singbox.SingboxConstants
import dev.amirzr.singbox.receivers.NotificationStopReceiver
import dev.amirzr.singbox.settings.NotificationConfig

internal object ServiceNotificationHelper {

    // ── Channel ───────────────────────────────────────────────────────────────

    fun createChannel(context: Context, config: NotificationConfig) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val ch = NotificationChannel(
                SingboxConstants.NOTIFICATION_CHANNEL_ID,
                config.channelName,
                NotificationManager.IMPORTANCE_LOW,
            )
            ch.setShowBadge(false)
            context.getSystemService(NotificationManager::class.java).createNotificationChannel(ch)
        }
    }

    // ── Build / post ──────────────────────────────────────────────────────────

    fun buildNotification(
        context: Context,
        config: NotificationConfig,
        title: String,
        text: String? = null,
    ) = NotificationCompat.Builder(context, SingboxConstants.NOTIFICATION_CHANNEL_ID)
        .setContentTitle(title)
        .apply { if (text != null) setContentText(text) }
        .setSmallIcon(context.applicationInfo.icon)
        .setOngoing(true)
        .setPriority(NotificationCompat.PRIORITY_LOW)
        .setVisibility(NotificationCompat.VISIBILITY_SECRET)
        .setContentIntent(getLauncherActivityIntent(context))
        .apply {
            if (config.showStopButton) {
                addAction(
                    0,
                    config.stopButtonLabel,
                    getStopActionIntent(context),
                )
            }
        }
        .build()

    fun updateNotification(
        context: Context,
        config: NotificationConfig,
        title: String,
        text: String? = null,
    ) {
        context.getSystemService(NotificationManager::class.java)
            .notify(SingboxConstants.NOTIFICATION_ID, buildNotification(context, config, title, text))
    }

    // ── Traffic update ────────────────────────────────────────────────────────

    /**
     * Posts a live-traffic notification update.
     * No-op if [NotificationConfig.showTrafficStats] is false.
     */
    fun updateForTraffic(
        context: Context,
        config: NotificationConfig,
        uplinkBps: Long,
        downlinkBps: Long,
    ) {
        val trafficText = "↑ ${formatBps(uplinkBps)}  ↓ ${formatBps(downlinkBps)}"
        updateNotification(context, config, config.title, trafficText)
    }

    // ── Formatting ────────────────────────────────────────────────────────────

    private fun formatBps(bps: Long): String = when {
        bps >= 1_000_000_000L -> "%.1f GB/s".format(bps / 1_000_000_000.0)
        bps >= 1_000_000L    -> "%.1f MB/s".format(bps / 1_000_000.0)
        bps >= 1_000L        -> "%.1f KB/s".format(bps / 1_000.0)
        else                 -> "$bps B/s"
    }

    // ── Intent helpers ────────────────────────────────────────────────────────

    private fun getLauncherActivityIntent(context: Context): PendingIntent {
        val pm = context.packageManager
        val intent = pm.getLaunchIntentForPackage(context.packageName)
            ?: Intent(Intent.ACTION_MAIN).apply {
                setPackage(context.packageName)
            }
        intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        return PendingIntent.getActivity(
            context,
            0,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun getStopActionIntent(context: Context): PendingIntent {
        val intent = Intent(context, NotificationStopReceiver::class.java).apply {
            action = NotificationStopReceiver.ACTION_STOP
        }
        return PendingIntent.getBroadcast(
            context,
            1,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

}
