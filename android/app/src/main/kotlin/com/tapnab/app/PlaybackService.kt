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
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Handler
import android.os.Looper
import java.net.URL
import kotlin.concurrent.thread
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
        instance = this
        applySession(applicationContext)
        val notification = build(this)
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
        instance = null
        releaseSession()
        abandonFocus()
        super.onDestroy()
    }

    companion object {
        @Volatile private var instance: PlaybackService? = null
        private const val CHANNEL_ID = "playback"
        private const val NOTIFICATION_ID = 1003
        const val ACTION_WEB_TOGGLE = "com.tapnab.app.web.TOGGLE"
        const val ACTION_WEB_PREV = "com.tapnab.app.web.PREV"
        const val ACTION_WEB_NEXT = "com.tapnab.app.web.NEXT"

        @Volatile private var title = "Tapnab"
        @Volatile private var videoId: String? = null
        @Volatile private var playing = true
        @Volatile private var positionMs = 0L
        @Volatile private var durationMs = 0L
        @Volatile private var thumbKey: String? = null
        @Volatile private var thumb: Bitmap? = null
        @Volatile private var thumbLoading: String? = null
        private var session: MediaSession? = null
        private var metaKey: String? = null
        private var focusRequest: AudioFocusRequest? = null

        fun start(context: Context) {
            ContextCompat.startForegroundService(context, Intent(context, PlaybackService::class.java))
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, PlaybackService::class.java))
        }

        /** Latest state from the in-app player: drives the lock-screen controls. */
        fun update(context: Context, id: String?, name: String, isPlaying: Boolean, pos: Long, dur: Long) {
            val app = context.applicationContext
            title = name.ifBlank { "Tapnab" }
            playing = isPlaying
            positionMs = pos
            durationMs = dur
            if (id != videoId) {
                videoId = id
                thumb = null
                thumbKey = null
            }
            val svc = instance ?: return
            applySession(app)
            if (isPlaying) svc.requestFocus()
            try {
                val nm = app.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                nm.notify(NOTIFICATION_ID, build(app))
            } catch (e: Exception) {
                // notifications may be blocked
            }
            loadThumb(app)
        }

        private fun loadThumb(app: Context) {
            val id = videoId ?: return
            if (id == thumbKey || id == thumbLoading) return
            thumbLoading = id
            thread(name = "play-thumb") {
                var bmp: Bitmap? = null
                try {
                    URL("https://i.ytimg.com/vi/$id/mqdefault.jpg").openStream().use {
                        bmp = BitmapFactory.decodeStream(it)
                    }
                } catch (e: Exception) {
                    // no picture
                }
                if (thumbLoading == id) thumbLoading = null
                if (videoId == id) {
                    thumbKey = id
                    thumb = bmp
                    if (bmp != null && instance != null) {
                        applySession(app)
                        try {
                            val nm = app.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                            nm.notify(NOTIFICATION_ID, build(app))
                        } catch (e: Exception) {
                            // ignore
                        }
                    }
                }
            }
        }

        @Synchronized
        private fun ensureSession(app: Context): MediaSession {
            session?.let { return it }
            val s = MediaSession(app, "TapnabPlayer")
            s.setCallback(object : MediaSession.Callback() {
                override fun onPlay() = emit("toggleOn")
                override fun onPause() = emit("toggleOff")
                override fun onSkipToNext() = emit("next")
                override fun onSkipToPrevious() = emit("prev")
                override fun onSeekTo(pos: Long) = emit("seek:" + pos)
                override fun onStop() = emit("toggleOff")
            }, Handler(Looper.getMainLooper()))
            s.isActive = true
            session = s
            metaKey = null
            return s
        }

        private fun emit(action: String) =
            DlnaCaster.emitExternal(mapOf("type" to "web", "action" to action))

        @Synchronized
        private fun releaseSession() {
            try {
                session?.isActive = false
                session?.release()
            } catch (e: Exception) {
                // already released
            }
            session = null
            metaKey = null
        }

        @Synchronized
        private fun applySession(app: Context) {
            val s = ensureSession(app)
            val actions = PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PAUSE or
                PlaybackState.ACTION_PLAY_PAUSE or PlaybackState.ACTION_SKIP_TO_NEXT or
                PlaybackState.ACTION_SKIP_TO_PREVIOUS or PlaybackState.ACTION_SEEK_TO or
                PlaybackState.ACTION_STOP
            s.setPlaybackState(
                PlaybackState.Builder()
                    .setActions(actions)
                    .setState(
                        if (playing) PlaybackState.STATE_PLAYING else PlaybackState.STATE_PAUSED,
                        positionMs,
                        if (playing) 1f else 0f,
                    )
                    .build(),
            )
            val art = if (videoId == thumbKey) thumb else null
            val key = "$title|$durationMs|${if (art != null) thumbKey else ""}"
            if (key != metaKey) {
                metaKey = key
                val meta = MediaMetadata.Builder()
                    .putString(MediaMetadata.METADATA_KEY_TITLE, title)
                    .putString(MediaMetadata.METADATA_KEY_ARTIST, "Tapnab")
                    .putLong(MediaMetadata.METADATA_KEY_DURATION, durationMs)
                if (art != null) meta.putBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART, art)
                s.setMetadata(meta.build())
            }
        }

        private fun button(context: Context, icon: Int, label: String, code: Int, act: String): Notification.Action =
            Notification.Action.Builder(
                Icon.createWithResource(context, icon), label,
                PendingIntent.getBroadcast(
                    context, code,
                    Intent(context, CastActionReceiver::class.java).setAction(act),
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
                ),
            ).build()

        @Suppress("DEPRECATION")
        private fun build(context: Context): Notification {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (nm.getNotificationChannel(CHANNEL_ID) == null) {
                nm.createNotificationChannel(
                    NotificationChannel(CHANNEL_ID, "Background playback", NotificationManager.IMPORTANCE_LOW).apply {
                        description = "Controls shown while a video or song plays"
                        setShowBadge(false)
                    },
                )
            }
            val open = PendingIntent.getActivity(
                context, 0,
                Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            val style = Notification.MediaStyle().setShowActionsInCompactView(0, 1, 2)
            session?.let { style.setMediaSession(it.sessionToken) }
            val b = Notification.Builder(context, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_stat_tapnab)
                .setContentTitle(title)
                .setContentText("Tapnab")
                .setOngoing(playing)
                .setOnlyAlertOnce(true)
                .setContentIntent(open)
                .setVisibility(Notification.VISIBILITY_PUBLIC)
                .addAction(button(context, R.drawable.ic_prev, "Previous", 11, ACTION_WEB_PREV))
                .addAction(
                    if (playing) button(context, R.drawable.ic_pause, "Pause", 12, ACTION_WEB_TOGGLE)
                    else button(context, R.drawable.ic_play, "Play", 12, ACTION_WEB_TOGGLE),
                )
                .addAction(button(context, R.drawable.ic_next, "Next", 13, ACTION_WEB_NEXT))
                .setStyle(style)
            if (videoId == thumbKey) thumb?.let { b.setLargeIcon(it) }
            return b.build()
        }
    }

    // ---- audio focus: other apps pause us and we pause for calls, like any player ----

    private val focusListener = AudioManager.OnAudioFocusChangeListener { change ->
        if (change == AudioManager.AUDIOFOCUS_LOSS || change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT) {
            if (playing) emit("toggleOff")
            focusRequest = null
        }
    }

    private fun requestFocus() {
        if (focusRequest != null) return
        try {
            val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            val req = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                        .build(),
                )
                .setOnAudioFocusChangeListener(focusListener)
                .build()
            am.requestAudioFocus(req)
            focusRequest = req
        } catch (e: Exception) {
            // playback still works without it
        }
    }

    private fun abandonFocus() {
        try {
            val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            focusRequest?.let { am.abandonAudioFocusRequest(it) }
        } catch (e: Exception) {
            // ignore
        }
        focusRequest = null
    }
}
