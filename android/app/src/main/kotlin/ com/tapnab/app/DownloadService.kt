package com.tapnab.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

/**
 * Foreground service whose only job is to keep the process (and therefore the
 * download queue) alive while the app is in the background. It stops itself
 * as soon as nothing is left to do.
 */
class DownloadService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        ensureChannel(this)
        val notification = build(this)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        instance = this
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        instance = null
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL_ID = "downloads"
        private const val NOTIFICATION_ID = 1001

        @Volatile private var instance: DownloadService? = null

        fun ensureRunning(context: Context) {
            val intent = Intent(context, DownloadService::class.java)
            androidx.core.content.ContextCompat.startForegroundService(context, intent)
        }

        /** Updates the notification, or stops the service when the queue is empty. */
        fun refresh() {
            val svc = instance ?: return
            if (DownloadManager.activeCount() == 0) {
                svc.stopForeground(STOP_FOREGROUND_REMOVE)
                svc.stopSelf()
                return
            }
            val nm = svc.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.notify(NOTIFICATION_ID, build(svc))
        }

        private fun ensureChannel(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (nm.getNotificationChannel(CHANNEL_ID) == null) {
                nm.createNotificationChannel(
                    NotificationChannel(CHANNEL_ID, "Downloads", NotificationManager.IMPORTANCE_LOW).apply {
                        description = "Shows download progress"
                        setShowBadge(false)
                    },
                )
            }
        }

        private fun build(context: Context): Notification {
            val snapshot = DownloadManager.snapshot()
            val active = snapshot.filter { it["status"] in setOf("queued", "fetching", "downloading", "converting") }
            val current = active.firstOrNull { it["status"] == "downloading" } ?: active.firstOrNull()
            val title = if (active.size > 1) "Downloading ${active.size} items" else "Downloading"
            val text = (current?.get("title") as? String) ?: (current?.get("url") as? String) ?: "Preparing..."
            val progress = ((current?.get("progress") as? Double) ?: 0.0).toInt()
            val indeterminate = current?.get("status") != "downloading"

            val open = PendingIntent.getActivity(
                context, 0,
                Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            return NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_stat_tapnab)
                .setContentTitle(title)
                .setContentText(text)
                .setProgress(100, progress, indeterminate)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setCategory(NotificationCompat.CATEGORY_PROGRESS)
                .setContentIntent(open)
                .build()
        }
    }
}
