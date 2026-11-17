package com.tapnab.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.drawable.Icon
import android.net.wifi.WifiManager
import android.os.IBinder
import android.os.PowerManager
import androidx.core.content.ContextCompat

/**
 * Keeps Tapnab alive (CPU and Wi-Fi awake) while a YouTube video plays inside the app,
 * so the sound continues with the screen off or in another app, like YouTube Premium.
 */
class PlaybackService : Service() {

    private var wake: PowerManager.WakeLock? = null
    private var wifi: WifiManager.WifiLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (nm.getNotificationChannel(CHANNEL_ID) == null) {
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Background playback", NotificationManager.IMPORTANCE_LOW).apply {
                    description = "Shown while a video plays in the background"
                    setShowBadge(false)
                },
            )
        }
        val open = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val toggle = PendingIntent.getBroadcast(
            this, 11,
            Intent(this, CastActionReceiver::class.java).setAction(ACTION_WEB_TOGGLE),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val notification = Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_tapnab)
            .setContentTitle("Tapnab")
            .setContentText("Playing in the background")
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(open)
            .addAction(
                Notification.Action.Builder(
                    Icon.createWithResource(this, R.drawable.ic_pause), "Play / Pause", toggle,
                ).build(),
            )
            .build()
        startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)

        if (wake == null) {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            wake = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "tapnab:playback").apply {
                setReferenceCounted(false)
                acquire(6 * 60 * 60 * 1000L)
            }
        }
        if (wifi == null) {
            val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            wifi = wm.createWifiLock(WifiManager.WIFI_MODE_FULL_LOW_LATENCY, "tapnab:playback").apply {
                setReferenceCounted(false)
                acquire()
            }
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        try {
            wake?.takeIf { it.isHeld }?.release()
            wifi?.takeIf { it.isHeld }?.release()
        } catch (e: Exception) {
            // already released
        }
        wake = null
        wifi = null
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL_ID = "playback"
        private const val NOTIFICATION_ID = 1003
        const val ACTION_WEB_TOGGLE = "com.tapnab.app.web.TOGGLE"
        const val ACTION_WEB_PREV = "com.tapnab.app.web.PREV"
        const val ACTION_WEB_NEXT = "com.tapnab.app.web.NEXT"

        fun start(context: Context) {
            ContextCompat.startForegroundService(context, Intent(context, PlaybackService::class.java))
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, PlaybackService::class.java))
        }
    }
}
