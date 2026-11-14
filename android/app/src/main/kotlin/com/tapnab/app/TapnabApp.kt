package com.tapnab.app

import android.app.Application
import android.util.Log
import com.yausername.ffmpeg.FFmpeg
import com.yausername.youtubedl_android.YoutubeDL
import java.util.concurrent.CountDownLatch
import kotlin.concurrent.thread

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

        fun awaitReady() {
            ready.await()
            initError?.let {
                throw IllegalStateException("Download engine failed to start: ${describe(it)}", it)
            }
        }

        private fun describe(t: Throwable): String {
            val parts = mutableListOf<String>()
            var cur: Throwable? = t
            while (cur != null && parts.size < 3) {
                val msg = cur.message?.takeIf { it.isNotBlank() }
                parts += if (msg != null) "${cur.javaClass.simpleName}: $msg" else cur.javaClass.simpleName
                cur = cur.cause
            }
            return parts.joinToString(" <- ")
        }
    }
}
