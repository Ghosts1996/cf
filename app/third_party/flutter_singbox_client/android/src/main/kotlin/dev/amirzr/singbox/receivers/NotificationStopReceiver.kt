package dev.amirzr.singbox.receivers

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import dev.amirzr.singbox.engine.SingboxManager

class NotificationStopReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "NotificationStopReceiver"
        const val ACTION_STOP = "dev.amirzr.singbox.STOP"
    }

    override fun onReceive(context: Context?, intent: Intent?) {
        if (intent?.action != ACTION_STOP || context == null) return
        Log.i(TAG, "Stop action triggered from notification")
        SingboxManager.getInstance(context).disconnect()
    }
}
