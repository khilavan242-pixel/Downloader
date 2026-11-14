package com.tapnab.app

import android.app.Application
import android.util.Log
import com.yausername.ffmpeg.FFmpeg
import com.yausername.youtubedl_android.YoutubeDL
import java.util.concurrent.CountDownLatch
import kotlin.concurrent.thread

/**
 * Initialises the bundled yt-dlp / FFmpeg once per process. Extraction of the
 * Python runtime takes a moment on first launch, so it happens off the main
 * thread and workers wait on [awaitReady] before running.
 */
class TapnabApp : Application() {

    override fun onCreate() {
        super.onCreate()
        thread(name = "ytdlp-init") {
            try {
                YoutubeDL.getInstance().init(this)
                FFmpeg.getInstance().init(this)
                initError = null
            } catch (t: Throwable) {
                Log.e(TAG, "yt-dlp init failed", t)
                initError = t
            } finally {
                ready.countDown()
            }
        }
    }

    companion object {
        private const val TAG = "TapnabApp"
        private val ready = CountDownLatch(1)

        @Volatile
        var initError: Throwable? = null
            private set

        /** Blocks the calling (worker) thread until the engine is usable. */
        fun awaitReady() {
            ready.await()
            initError?.let { throw IllegalStateException("Download engine failed to start: ${it.message}", it) }
        }
    }
}
