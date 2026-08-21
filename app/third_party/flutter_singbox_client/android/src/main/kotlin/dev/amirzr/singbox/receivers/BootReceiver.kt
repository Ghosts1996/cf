package dev.amirzr.singbox.receivers

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Stateless boot trigger. On device boot or app update, broadcasts
 * [ACTION_DEVICE_BOOTED] to the host app. The host app decides whether
 * to reconnect and calls connect() with its own stored config.
 */
class BootReceiver : BroadcastReceiver() {

    companion object {
        const val ACTION_DEVICE_BOOTED = "dev.amirzr.singbox.DEVICE_BOOTED"
        private const val TAG = "BootReceiver"
    }

    override fun onReceive(context: Context, intent: Intent?) {
        when (intent?.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED -> {
                Log.i(TAG, "Boot/update detected — notifying host app")
                val bootIntent = Intent(ACTION_DEVICE_BOOTED).apply {
                    setPackage(context.packageName)
                }
                context.sendBroadcast(bootIntent)
            }
        }
    }
}
