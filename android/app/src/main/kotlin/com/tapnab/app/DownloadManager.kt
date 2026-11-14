package com.tapnab.app

import android.content.Context
import android.util.Log
import com.yausername.youtubedl_android.YoutubeDL
import java.io.File
import java.util.concurrent.Executors

object DownloadManager {

    private const val TAG = "DownloadManager"
    private const val MAX_PARALLEL = 2

    class Task(
        val id: String,
        val url: String,
        val kind: String, // "mp3" | "mp4"
        val quality: Int,
        val playlist: Boolean,
        val folderUri: String?,
    ) {
        @Volatile var status: String = "queued"
        @Volatile var progress: Double = 0.0
        @Volatile var eta: Long = -1
        @Volatile var title: String? = null
        @Volatile var error: String? = null
        @Volatile var savedTo: String? = null
        @Volatile var cancelled: Boolean = false

        val isAudio get() = kind == "mp3"

        fun toMap(): Map<String, Any?> = mapOf(
            "id" to id, "url" to url, "kind" to kind, "quality" to quality, "playlist" to playlist,
            "status" to status, "progress" to progress, "eta" to eta,
            "title" to title, "error" to error, "savedTo" to savedTo,
        )
    }

    private val tasks = LinkedHashMap<String, Task>()
    private val executor = Executors.newFixedThreadPool(MAX_PARALLEL)

    @Volatile var listener: ((Map<String, Any?>) -> Unit)? = null

    fun snapshot(): List<Map<String, Any?>> = synchronized(tasks) { tasks.values.map { it.toMap() } }

    fun activeCount(): Int = synchronized(tasks) {
        tasks.values.count { it.status in ACTIVE }
    }

    private val ACTIVE = setOf("queued", "fetching", "downloading", "converting")

    fun enqueue(context: Context, task: Task) {
        val app = context.applicationContext
        synchronized(tasks) { tasks[task.id] = task }
        DownloadService.ensureRunning(app)
        emit(task)
        executor.execute { run(app, task) }
    }

    fun cancel(id: String) {
        val t = synchronized(tasks) { tasks[id] } ?: return
        t.cancelled = true
        try {
            YoutubeDL.getInstance().destroyProcessById(id)
        } catch (e: Throwable) {
            Log.w(TAG, "destroyProcessById failed", e)
        }
        if (t.status == "queued") {
            t.status = "cancelled"
            emit(t)
            DownloadService.refresh()
        }
    }

    private fun expandPlaylist(context: Context, t: Task): Boolean {
        t.status = "fetching"
        emit(t)
        val entries: List<Pair<String, String>> = try {
            TapnabApp.awaitReady()
            val req = com.yausername.youtubedl_android.YoutubeDLRequest(t.url).apply {
                addOption("--flat-playlist")
                addOption("--yes-playlist")
                addOption("--no-warnings")
                addOption("--print", "%(webpage_url,url,id)s\t%(title)s")
            }
            val out = YoutubeDL.getInstance().execute(req, t.id) { _, _, _ -> }.out
            out.lineSequence().mapNotNull { line ->
                val parts = line.split('\t', limit = 2)
                val ref = parts[0].trim()
                if (ref.isEmpty() || ref == "NA") {
                    null
                } else {
                    val url = if (ref.startsWith("http")) ref else "https://www.youtube.com/watch?v=$ref"
                    url to parts.getOrNull(1).orEmpty().trim()
                }
            }.toList()
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

        entries.forEachIndexed { i, (url, title) ->
            val child = Task(
                id = "${t.id}-${i + 1}",
                url = url,
                kind = t.kind,
                quality = t.quality,
                playlist = false,
                folderUri = t.folderUri,
            )
            if (title.isNotEmpty() && title != "NA") child.title = title
            enqueue(context, child)
        }
        synchronized(tasks) { tasks.remove(t.id) }
        listener?.invoke(mapOf("type" to "playlist", "id" to t.id, "count" to entries.size))
        DownloadService.refresh()
        return true
    }

    private fun run(context: Context, t: Task) {
        if (t.cancelled) {
            finish(t, "cancelled")
            return
        }
        if (t.playlist && expandPlaylist(context, t)) return
        val workDir = File(context.cacheDir, "dl/${t.id}").apply { mkdirs() }
        try {
            t.status = "fetching"
            emit(t)
            TapnabApp.awaitReady()

            val request = YtdlpOptions.build(t.url, t.isAudio, t.quality, t.playlist, workDir)
            var lastPercent = -1
            YoutubeDL.getInstance().execute(request, t.id) { progress, eta, line ->
                if (t.cancelled) return@execute
                var changed = false
                if (line.startsWith("[download] Destination:") && t.title == null) {
                    t.title = File(line.substringAfter("Destination:").trim()).nameWithoutExtension
                    changed = true
                }
                val converting = line.startsWith("[ExtractAudio]") || line.startsWith("[Merger]") ||
                    line.startsWith("[VideoConvertor]") || line.startsWith("[Metadata]")
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
            if (t.cancelled) {
                finish(t, "cancelled")
                return
            }

            val produced = workDir.listFiles { f -> f.isFile && f.extension.lowercase() in MEDIA_EXT }
                ?.sortedBy { it.name }.orEmpty()
            if (produced.isEmpty()) throw IllegalStateException("No file was produced. Try another quality.")

            var where = ""
            for (f in produced) where = FileSaver.save(context, f, t.isAudio, t.folderUri)
            t.savedTo = where
            t.progress = 100.0
            if (t.title == null) t.title = produced.first().nameWithoutExtension
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

    private fun finish(t: Task, status: String) {
        t.status = status
        emit(t)
        DownloadService.refresh()
    }

    private fun emit(t: Task) {
        listener?.invoke(t.toMap())
    }

    private val MEDIA_EXT = setOf("mp3", "mp4", "m4a", "webm", "mkv")
}
