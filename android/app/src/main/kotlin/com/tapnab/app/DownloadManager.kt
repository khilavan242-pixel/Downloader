package com.tapnab.app

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.util.Log
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.youtubedl_android.YoutubeDLRequest
import java.io.File
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

/**
 * Owns the download queue. Lives in the process (not the Activity), so
 * downloads continue while the app is in the background; [DownloadService]
 * keeps the process alive with a foreground notification.
 */
object DownloadManager {

    private const val TAG = "DownloadManager"

    class Task(
        val id: String,
        val url: String,
        val kind: String, // "mp3" | "mp4"
        val quality: Int,
        val playlist: Boolean,
        val folderUri: String?,
        /** Sub-folder inside the destination (playlist name), or null. */
        subfolder: String? = null,
    ) {
        @Volatile var subfolder: String? = subfolder
        val createdAt: Long = System.currentTimeMillis()
        @Volatile var finishedAt: Long = -1
        @Volatile var status: String = "queued"
        @Volatile var progress: Double = 0.0
        @Volatile var eta: Long = -1
        @Volatile var title: String? = null
        @Volatile var error: String? = null
        @Volatile var note: String? = null
        @Volatile var savedTo: String? = null
        @Volatile var fileUri: String? = null
        @Volatile var fileSize: Long = -1
        @Volatile var cancelled: Boolean = false

        val isAudio get() = kind == "mp3"

        fun toMap(): Map<String, Any?> = mapOf(
            "id" to id, "url" to url, "kind" to kind, "quality" to quality, "playlist" to playlist,
            "status" to status, "progress" to progress, "eta" to eta,
            "title" to title, "error" to error, "note" to note, "savedTo" to savedTo,
            "fileUri" to fileUri, "fileSize" to fileSize,
            "subfolder" to subfolder, "createdAt" to createdAt,
            "finishedAt" to (if (finishedAt > 0) finishedAt else null),
        )
    }

    private val ACTIVE = setOf("queued", "fetching", "downloading", "converting")
    private val FINISHED = setOf("completed", "failed", "cancelled")
    private val MEDIA_EXT = setOf("mp3", "mp4", "m4a", "webm", "mkv")

    private val tasks = LinkedHashMap<String, Task>()

    // Core == max, so the pool size is exactly the "parallel downloads" setting.
    private val executor = ThreadPoolExecutor(2, 2, 60L, TimeUnit.SECONDS, LinkedBlockingQueue()).apply {
        allowCoreThreadTimeOut(true)
    }

    /** Set by the Flutter channel; invoked from worker threads. */
    @Volatile var listener: ((Map<String, Any?>) -> Unit)? = null

    /**
     * Everything the native side knows. Finished items are handed over once and
     * then forgotten here, so a list cleared in the app never comes back.
     */
    fun snapshot(): List<Map<String, Any?>> = synchronized(tasks) {
        val all = tasks.values.map { it.toMap() }
        tasks.values.removeAll { it.status in FINISHED }
        all
    }

    /** Running items only, without handing anything over (used by the notification). */
    fun activeSnapshot(): List<Map<String, Any?>> = synchronized(tasks) {
        tasks.values.filter { it.status in ACTIVE }.map { it.toMap() }
    }

    fun activeCount(): Int = synchronized(tasks) { tasks.values.count { it.status in ACTIVE } }

    fun enqueue(context: Context, task: Task) {
        val app = context.applicationContext
        applyParallel(app)
        synchronized(tasks) { tasks[task.id] = task }
        DownloadService.ensureRunning(app)
        emit(task)
        executor.execute { run(app, task) }
    }

    private fun applyParallel(context: Context) {
        val n = AppSettings.parallel(context)
        if (n > executor.maximumPoolSize) {
            executor.maximumPoolSize = n
            executor.corePoolSize = n
        } else {
            executor.corePoolSize = n
            executor.maximumPoolSize = n
        }
    }

    fun cancel(id: String) {
        val t = synchronized(tasks) { tasks[id] } ?: return
        t.cancelled = true
        // Kills the yt-dlp process if it is running; harmless when it is only queued.
        try {
            YoutubeDL.getInstance().destroyProcessById(id)
        } catch (e: Throwable) {
            Log.w(TAG, "destroyProcessById failed", e)
        }
        if (t.status == "queued") {
            t.note = null
            finish(t, "cancelled")
        }
    }

    /** One playlist entry as shown in the "pick songs" screen. */
    class Entry(val url: String, val title: String, val duration: String, val playlist: String)

    /** Lists a playlist (or a single video) without downloading anything. */
    fun listPlaylist(url: String): List<Entry> {
        TapnabApp.awaitReady()
        val req = YoutubeDLRequest(url).apply {
            addOption("--flat-playlist")
            addOption("--yes-playlist")
            addOption("--no-warnings")
            addOption(
                "--print",
                "%(webpage_url,url,id)s\t%(title)s\t%(duration_string)s\t%(playlist_title,playlist)s",
            )
        }
        val out = YoutubeDL.getInstance().execute(req, null) { _, _, _ -> }.out
        return out.lineSequence().mapNotNull { line ->
            val parts = line.split('\t', limit = 4)
            val ref = parts[0].trim()
            if (ref.isEmpty() || ref == "NA") return@mapNotNull null
            val title = parts.getOrNull(1).orEmpty().trim()
            if (title.startsWith("[Private video]") || title.startsWith("[Deleted video]")) return@mapNotNull null
            val link = if (ref.startsWith("http")) ref else "https://www.youtube.com/watch?v=$ref"
            Entry(
                url = link,
                title = if (title == "NA") "" else title,
                duration = parts.getOrNull(2).orEmpty().trim().let { if (it == "NA") "" else it },
                playlist = parts.getOrNull(3).orEmpty().trim().let { if (it == "NA") "" else it },
            )
        }.toList()
    }

    /**
     * Turns a playlist link into one task per song, so each song gets its own
     * card, progress bar and is saved as soon as it finishes.
     *
     * @return true when the task was fully handled here (songs queued, or the
     *         user cancelled); false to fall back to downloading it as one task.
     */
    private fun expandPlaylist(context: Context, t: Task): Boolean {
        t.status = "fetching"
        emit(t)
        val entries: List<Entry> = try {
            listPlaylist(t.url)
        } catch (e: YoutubeDL.CanceledException) {
            finish(t, "cancelled")
            return true
        } catch (e: Throwable) {
            Log.w(TAG, "playlist expansion failed, downloading as one task", e)
            return false
        }

        if (t.cancelled) {
            finish(t, "cancelled")
            return true
        }
        if (entries.size < 2) return false

        val folder = if (AppSettings.playlistFolders(context)) {
            t.subfolder ?: entries.firstOrNull { it.playlist.isNotBlank() }?.playlist?.let(NameCleaner::folderName)
        } else {
            null
        }

        entries.forEachIndexed { i, e ->
            val child = Task(
                id = "${t.id}-${i + 1}",
                url = e.url,
                kind = t.kind,
                quality = t.quality,
                playlist = false,
                folderUri = t.folderUri,
                subfolder = folder,
            )
            if (e.title.isNotEmpty()) child.title = NameCleaner.apply(e.title, AppSettings.nameStyle(context))
            enqueue(context, child)
        }
        // The playlist card is replaced by its songs.
        synchronized(tasks) { tasks.remove(t.id) }
        listener?.invoke(mapOf("type" to "playlist", "id" to t.id, "count" to entries.size))
        DownloadService.refresh()
        return true
    }

    private fun isUnmetered(context: Context): Boolean {
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val caps = cm.getNetworkCapabilities(cm.activeNetwork) ?: return false
        return caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
    }

    /** Holds the task in the queue until Wi-Fi is available (when the setting is on). */
    private fun waitForWifi(context: Context, t: Task) {
        if (!AppSettings.wifiOnly(context) || isUnmetered(context)) return
        t.note = "Waiting for Wi-Fi"
        emit(t)
        while (!t.cancelled && AppSettings.wifiOnly(context) && !isUnmetered(context)) {
            try {
                Thread.sleep(3000)
            } catch (e: InterruptedException) {
                break
            }
        }
        t.note = null
    }

    private fun run(context: Context, t: Task) {
        if (t.cancelled) {
            finish(t, "cancelled")
            return
        }
        waitForWifi(context, t)
        if (t.cancelled) {
            finish(t, "cancelled")
            return
        }
        if (t.playlist && expandPlaylist(context, t)) return

        val style = AppSettings.nameStyle(context)
        val workDir = File(context.cacheDir, "dl/${t.id}").apply { mkdirs() }
        try {
            t.status = "fetching"
            emit(t)
            TapnabApp.awaitReady()

            val wantArt = t.isAudio && AppSettings.coverArt(context)
            try {
                runYtdlp(t, workDir, wantArt, style)
            } catch (e: YoutubeDL.CanceledException) {
                throw e
            } catch (e: Throwable) {
                // Album art is a bonus: if embedding it fails, download again without it.
                val m = e.message.orEmpty().lowercase()
                val artProblem = wantArt && !t.cancelled &&
                    listOf("thumbnail", "postprocess", "embed", "atomicparsley", "mutagen", "ffmpeg").any { it in m }
                if (!artProblem) throw e
                Log.w(TAG, "cover art failed, retrying without it", e)
                workDir.listFiles()?.forEach { it.deleteRecursively() }
                t.progress = 0.0
                runYtdlp(t, workDir, false, style)
            }
            if (t.cancelled) {
                finish(t, "cancelled")
                return
            }

            val produced = workDir.listFiles { f -> f.isFile && f.extension.lowercase() in MEDIA_EXT }
                ?.sortedBy { it.name }.orEmpty()
            if (produced.isEmpty()) throw IllegalStateException("No file was produced. Try another quality.")

            var saved: FileSaver.Saved? = null
            var shownName: String? = null
            for (f in produced) {
                val cleaned = NameCleaner.apply(f.nameWithoutExtension, style)
                shownName = cleaned
                saved = FileSaver.save(
                    context, f, t.isAudio, t.folderUri,
                    displayName = "$cleaned.${f.extension}",
                    subfolder = t.subfolder,
                )
            }
            t.savedTo = saved?.label
            t.fileUri = saved?.uri?.toString()
            t.fileSize = saved?.size ?: -1
            t.progress = 100.0
            t.title = shownName ?: t.title
            finish(t, "completed")
        } catch (e: YoutubeDL.CanceledException) {
            finish(t, "cancelled")
        } catch (e: Throwable) {
            if (t.cancelled) {
                finish(t, "cancelled")
            } else {
                Log.e(TAG, "download failed: ${t.url}", e)
                t.error = YtdlpOptions.friendlyError(e.message)
                finish(t, "failed")
            }
        } finally {
            workDir.deleteRecursively()
        }
    }

    private fun runYtdlp(t: Task, workDir: File, coverArt: Boolean, style: String) {
        val request = YtdlpOptions.build(t.url, t.isAudio, t.quality, t.playlist, workDir, coverArt)
        var lastPercent = -1
        YoutubeDL.getInstance().execute(request, t.id) { progress, eta, line ->
            if (t.cancelled) return@execute
            var changed = false
            if (line.startsWith("[download] Destination:") && t.title == null) {
                val raw = File(line.substringAfter("Destination:").trim()).nameWithoutExtension
                t.title = NameCleaner.apply(raw, style)
                changed = true
            }
            val converting = line.startsWith("[ExtractAudio]") || line.startsWith("[Merger]") ||
                line.startsWith("[VideoConvertor]") || line.startsWith("[Metadata]") ||
                line.startsWith("[EmbedThumbnail]") || line.startsWith("[ThumbnailsConvertor]")
            if (converting && t.status != "converting") {
                t.status = "converting"
                changed = true
            } else if (!converting && progress >= 0f && t.status != "converting") {
                val pct = progress.toInt()
                if (t.status != "downloading" || pct != lastPercent) {
                    lastPercent = pct
                    t.status = "downloading"
                    t.progress = progress.toDouble()
                    t.eta = eta
                    changed = true
                }
            }
            if (changed) {
                emit(t)
                DownloadService.refresh()
            }
        }
    }

    private fun finish(t: Task, status: String) {
        t.status = status
        t.finishedAt = System.currentTimeMillis()
        emit(t)
        DownloadService.refresh()
    }

    private fun emit(t: Task) {
        listener?.invoke(t.toMap())
    }
}
