package com.tapnab.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.drawable.Icon
import android.os.Build
import android.os.IBinder
import androidx.core.content.ContextCompat
import java.net.URL
import kotlin.concurrent.thread

/**
 * Keeps the app alive while it is casting to a TV, and shows a media-style
 * notification (previous, play/pause, next, stop) like a video player.
 */
class CastService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val device = intent?.getStringExtra(EXTRA_DEVICE) ?: "TV"
        running = true
        if (lastState == null || lastState?.get("device") != device) {
            lastState = mapOf("status" to "loading", "device" to device)
        }
        val notification = build(this, lastState!!)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        running = false
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL_ID = "casting"
        private const val NOTIFICATION_ID = 1002
        private const val EXTRA_DEVICE = "device"

        const val ACTION_PREV = "com.tapnab.app.cast.PREV"
        const val ACTION_TOGGLE = "com.tapnab.app.cast.TOGGLE"
        const val ACTION_NEXT = "com.tapnab.app.cast.NEXT"
        const val ACTION_STOP = "com.tapnab.app.cast.STOP"

        @Volatile private var running = false
        @Volatile private var lastState: Map<String, Any?>? = null
        @Volatile private var thumbId: String? = null
        @Volatile private var thumb: Bitmap? = null
        @Volatile private var thumbLoading: String? = null

        fun start(context: Context, deviceName: String) {
            val intent = Intent(context, CastService::class.java).putExtra(EXTRA_DEVICE, deviceName)
            ContextCompat.startForegroundService(context, intent)
        }

        fun stop(context: Context) {
            lastState = null
            context.stopService(Intent(context, CastService::class.java))
        }

        /** Refreshes the notification with the latest playback state. */
        fun update(context: Context, state: Map<String, Any?>) {
            lastState = state
            if (!running) return
            val app = context.applicationContext
            try {
                val nm = app.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                nm.notify(NOTIFICATION_ID, build(app, state))
            } catch (e: Exception) {
                // Notifications may be blocked; casting still works.
            }
            loadThumb(app, state)
        }

        private val idRegex = Regex("""(?:v=|youtu\.be/|shorts/)([A-Za-z0-9_-]{11})""")

        private fun loadThumb(app: Context, state: Map<String, Any?>) {
            val uri = state["pageUrl"] as? String ?: state["uri"] as? String ?: return
            val id = idRegex.find(uri)?.groupValues?.get(1) ?: return
            if (id == thumbId || id == thumbLoading) return
            thumbLoading = id
            thumb = null
            thread(name = "cast-thumb") {
                var bmp: Bitmap? = null
                try {
                    URL("https://i.ytimg.com/vi/$id/mqdefault.jpg").openStream().use {
                        bmp = BitmapFactory.decodeStream(it)
                    }
                } catch (e: Exception) {
                    // no thumbnail, the notification still works
                }
                thumbId = id
                thumbLoading = null
                thumb = bmp
                if (bmp != null && running) {
                    lastState?.let { s ->
                        try {
                            val nm = app.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                            nm.notify(NOTIFICATION_ID, build(app, s))
                        } catch (e: Exception) {
                            // ignore
                        }
                    }
                }
            }
        }

        private fun action(context: Context, code: Int, act: String): PendingIntent =
            PendingIntent.getBroadcast(
                context, code,
                Intent(act).setPackage(context.packageName),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )

        private fun button(context: Context, icon: Int, label: String, code: Int, act: String): Notification.Action =
            Notification.Action.Builder(Icon.createWithResource(context, icon), label, action(context, code, act)).build()

        @Suppress("DEPRECATION")
        private fun build(context: Context, state: Map<String, Any?>): Notification {
            ensureChannel(context)
            val device = state["device"] as? String ?: "TV"
            val status = state["status"] as? String ?: "loading"
            val title = (state["title"] as? String)?.takeIf { it.isNotBlank() } ?: "Casting to $device"
            val paused = status == "paused"

            val open = PendingIntent.getActivity(
                context, 0,
                Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            val b = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(context, CHANNEL_ID)
            } else {
                Notification.Builder(context)
            }
            b.setSmallIcon(R.drawable.ic_stat_tapnab)
                .setContentTitle(title)
                .setContentText(if (status == "loading") "Starting on $device..." else "Casting to $device")
                .setSubText(device)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setContentIntent(open)
                .setVisibility(Notification.VISIBILITY_PUBLIC)
                .addAction(button(context, R.drawable.ic_prev, "Previous", 1, ACTION_PREV))
                .addAction(
                    if (paused) button(context, R.drawable.ic_play, "Play", 2, ACTION_TOGGLE)
                    else button(context, R.drawable.ic_pause, "Pause", 2, ACTION_TOGGLE),
                )
                .addAction(button(context, R.drawable.ic_next, "Next", 3, ACTION_NEXT))
                .addAction(button(context, R.drawable.ic_stop, "Stop", 4, ACTION_STOP))
                .setStyle(Notification.MediaStyle().setShowActionsInCompactView(0, 1, 2))
            val uri = state["pageUrl"] as? String ?: state["uri"] as? String
            val id = uri?.let { idRegex.find(it)?.groupValues?.get(1) }
            if (id != null && id == thumbId) thumb?.let { b.setLargeIcon(it) }
            return b.build()
        }

        private fun ensureChannel(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (nm.getNotificationChannel(CHANNEL_ID) == null) {
                nm.createNotificationChannel(
                    NotificationChannel(CHANNEL_ID, "Casting", NotificationManager.IMPORTANCE_LOW).apply {
                        description = "Controls shown while playing on a TV"
                        setShowBadge(false)
                    },
                )
            }
        }
    }
}
