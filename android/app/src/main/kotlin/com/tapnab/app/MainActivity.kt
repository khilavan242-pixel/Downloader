package com.tapnab.app

import android.Manifest
import android.app.PendingIntent
import android.app.PictureInPictureParams
import android.app.RemoteAction
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.drawable.Icon
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.util.Rational
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.yausername.youtubedl_android.YoutubeDL
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlin.concurrent.thread

/**
 * Bridges Flutter <-> native: method calls for commands, an event stream for
 * task updates, the system folder picker, and "Share -> Tapnab" links.
 */
class MainActivity : FlutterActivity() {

    private val main = Handler(Looper.getMainLooper())
    private lateinit var folders: FolderStore

    private var eventSink: EventChannel.EventSink? = null
    private var pendingFolderResult: MethodChannel.Result? = null
    private var pendingMediaResult: MethodChannel.Result? = null
    private var pipReady = false
    private var keepWeb = false
    private var pipPlaying = false
    private var pendingShared: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        folders = FolderStore(this)
        captureShared(intent)
        requestNotificationPermission()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        captureShared(intent)
        // App already running: push straight to Dart instead of waiting for a poll.
        val sink = eventSink
        val text = pendingShared
        if (sink != null && text != null) {
            pendingShared = null
            sink.success(mapOf("type" to "shared", "text" to text))
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        EventChannel(messenger, "tapnab/events").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                eventSink = events
                DownloadManager.listener = { map -> main.post { eventSink?.success(map) } }
                DlnaCaster.listener = { map -> main.post { eventSink?.success(map) } }
            }

            override fun onCancel(arguments: Any?) {
                eventSink = null
                DownloadManager.listener = null
                DlnaCaster.listener = null
            }
        })

        MethodChannel(messenger, "tapnab/downloader").setMethodCallHandler(::onMethodCall)
    }

    private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "enqueue" -> {
                val id = call.argument<String>("id")
                val url = call.argument<String>("url")
                if (id == null || url == null) {
                    result.error("bad_args", "id and url are required", null)
                    return
                }
                DownloadManager.enqueue(
                    this,
                    DownloadManager.Task(
                        id = id,
                        url = url,
                        kind = call.argument<String>("kind") ?: "mp3",
                        quality = call.argument<Int>("quality") ?: 0,
                        playlist = call.argument<Boolean>("playlist") ?: false,
                        folderUri = call.argument<String>("folderUri"),
                        subfolder = call.argument<String>("subfolder")?.takeIf { it.isNotBlank() }?.let(NameCleaner::folderName),
                    ),
                )
                result.success(null)
            }

            "cancel" -> {
                call.argument<String>("id")?.let(DownloadManager::cancel)
                result.success(null)
            }

            "snapshot" -> result.success(DownloadManager.snapshot())

            "pickFolder" -> {
                if (pendingFolderResult != null) {
                    result.error("busy", "Folder picker already open", null)
                    return
                }
                pendingFolderResult = result
                val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).addFlags(
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                        Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                        Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
                        Intent.FLAG_GRANT_PREFIX_URI_PERMISSION,
                )
                @Suppress("DEPRECATION")
                startActivityForResult(intent, REQUEST_FOLDER)
            }

            "listFolders" -> result.success(folders.list().map { it.toMap() })

            "removeFolder" -> {
                call.argument<String>("uri")?.let(folders::remove)
                result.success(null)
            }

            "updateEngine" -> thread(name = "ytdlp-update") {
                try {
                    TapnabApp.awaitReady()
                    YoutubeDL.getInstance().updateYoutubeDL(applicationContext, YoutubeDL.UpdateChannel.STABLE)
                    TapnabApp.markUpdated(applicationContext)
                    val version = YoutubeDL.getInstance().version(applicationContext) ?: "unknown"
                    main.post { result.success(version) }
                } catch (e: Throwable) {
                    main.post { result.error("update_failed", e.message ?: "Update failed", null) }
                }
            }

            "openFile" -> {
                val uri = call.argument<String>("uri")?.let(Uri::parse)
                if (uri == null) {
                    result.success(false)
                    return
                }
                val view = Intent(Intent.ACTION_VIEW)
                    .setDataAndType(uri, call.argument<String>("mime") ?: "*/*")
                    .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                try {
                    startActivity(view)
                    result.success(true)
                } catch (e: ActivityNotFoundException) {
                    result.success(false)
                } catch (e: Exception) {
                    result.success(false)
                }
            }

            "shareFile" -> {
                val uri = call.argument<String>("uri")?.let(Uri::parse)
                if (uri == null) {
                    result.success(false)
                    return
                }
                val mime = call.argument<String>("mime") ?: "*/*"
                val send = Intent(Intent.ACTION_SEND).apply {
                    type = mime
                    putExtra(Intent.EXTRA_STREAM, uri)
                    clipData = ClipData.newRawUri("", uri)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
                try {
                    startActivity(Intent.createChooser(send, call.argument<String>("title") ?: "Share"))
                    result.success(true)
                } catch (e: Exception) {
                    result.success(false)
                }
            }

            "shareFiles" -> {
                val uris = ArrayList<Uri>(call.argument<List<String>>("uris").orEmpty().map(Uri::parse))
                if (uris.isEmpty()) {
                    result.success(false)
                    return
                }
                val send = Intent(Intent.ACTION_SEND_MULTIPLE).apply {
                    type = call.argument<String>("mime") ?: "*/*"
                    putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris)
                    val clip = ClipData.newRawUri("", uris[0])
                    for (i in 1 until uris.size) clip.addItem(ClipData.Item(uris[i]))
                    clipData = clip
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
                try {
                    startActivity(Intent.createChooser(send, call.argument<String>("title") ?: "Share"))
                    result.success(true)
                } catch (e: Exception) {
                    result.success(false)
                }
            }

            "deleteFile" -> {
                val uri = call.argument<String>("uri")?.let(Uri::parse)
                if (uri == null) {
                    result.success(false)
                    return
                }
                thread(name = "delete-file") {
                    val ok = try {
                        if (DocumentsContract.isDocumentUri(this, uri)) {
                            DocumentsContract.deleteDocument(contentResolver, uri)
                        } else {
                            contentResolver.delete(uri, null, null) > 0
                        }
                    } catch (e: Exception) {
                        false
                    }
                    main.post { result.success(ok) }
                }
            }

            "filesExist" -> {
                val uris = call.argument<List<String>>("uris").orEmpty()
                thread(name = "files-exist") {
                    val exists = uris.map { s ->
                        try {
                            contentResolver.openFileDescriptor(Uri.parse(s), "r")?.use { true } ?: false
                        } catch (e: Exception) {
                            false
                        }
                    }
                    main.post { result.success(exists) }
                }
            }

            "engineVersion" -> thread(name = "ytdlp-version") {
                val info = try {
                    TapnabApp.awaitReady()
                    mapOf(
                        "version" to (YoutubeDL.getInstance().version(applicationContext) ?: "unknown"),
                        "lastUpdate" to TapnabApp.lastUpdate(applicationContext),
                    )
                } catch (e: Throwable) {
                    mapOf("version" to "unavailable", "lastUpdate" to 0L)
                }
                main.post { result.success(info) }
            }

            "fetchPlaylist" -> {
                val url = call.argument<String>("url")
                if (url == null) {
                    result.error("bad_args", "url is required", null)
                    return
                }
                thread(name = "playlist-list") {
                    try {
                        val list = DownloadManager.listPlaylist(url).map {
                            mapOf("url" to it.url, "title" to it.title, "duration" to it.duration, "playlist" to it.playlist)
                        }
                        main.post { result.success(list) }
                    } catch (e: Throwable) {
                        main.post { result.error("playlist_failed", YtdlpOptions.friendlyError(e.message), null) }
                    }
                }
            }

            "playFiles" -> {
                val uris = ArrayList<Uri>(call.argument<List<String>>("uris").orEmpty().map(Uri::parse))
                if (uris.isEmpty()) {
                    result.success(false)
                    return
                }
                // Players take the first item as the one to open; the rest ride along
                // in ClipData for players that queue them all.
                val view = Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(uris[0], call.argument<String>("mime") ?: "audio/*")
                    val clip = ClipData.newRawUri("", uris[0])
                    for (i in 1 until uris.size) clip.addItem(ClipData.Item(uris[i]))
                    clipData = clip
                    putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
                try {
                    startActivity(Intent.createChooser(view, call.argument<String>("title") ?: "Play with"))
                    result.success(true)
                } catch (e: Exception) {
                    result.success(false)
                }
            }

            "castDiscover" -> thread(name = "dlna-discover") {
                val list = try {
                    DlnaCaster.discover(applicationContext).map { it.toMap() }
                } catch (e: Throwable) {
                    emptyList()
                }
                main.post { result.success(list) }
            }

            "castPlay" -> {
                val device = call.argument<Map<String, Any?>>("device")
                val items = call.argument<List<Map<String, Any?>>>("items").orEmpty()
                val control = device?.get("controlUrl") as? String
                val type = device?.get("serviceType") as? String
                if (device == null || control == null || type == null || items.isEmpty()) {
                    result.error("bad_args", "device and items are required", null)
                    return
                }
                thread(name = "dlna-start") {
                    try {
                        DlnaCaster.start(
                            applicationContext,
                            DlnaCaster.Device(
                                device["name"] as? String ?: "TV",
                                control,
                                type,
                                (device["renderUrl"] as? String)?.takeIf { it.isNotEmpty() },
                                (device["renderType"] as? String)?.takeIf { it.isNotEmpty() },
                            ),
                            items.map {
                                DlnaCaster.Item(
                                    it["uri"] as? String ?: "",
                                    it["title"] as? String ?: "",
                                    it["mime"] as? String ?: "video/mp4",
                                    it["stream"] as? Boolean ?: false,
                                )
                            },
                        )
                        main.post { result.success(true) }
                    } catch (e: Throwable) {
                        main.post { result.error("cast_failed", e.message ?: "Could not reach the TV", null) }
                    }
                }
            }

            "castControl" -> {
                DlnaCaster.control(call.argument<String>("action") ?: "", call.argument<Int>("value") ?: 0)
                result.success(null)
            }

            "castState" -> result.success(DlnaCaster.state())

            "keepAlive" -> {
                keepWeb = call.argument<Boolean>("on") == true
                try {
                    if (call.argument<Boolean>("on") == true) PlaybackService.start(applicationContext)
                    else PlaybackService.stop(applicationContext)
                } catch (e: Exception) {
                    // Android may refuse to start a service while the app is in the background.
                }
                result.success(null)
            }

            "setPip" -> {
                pipReady = call.argument<Boolean>("ready") == true
                pipPlaying = call.argument<Boolean>("playing") == true
                applyPipParams()
                result.success(null)
            }

            "resolveStream" -> {
                val url = call.argument<String>("url")
                if (url == null) {
                    result.error("bad_args", "url is required", null)
                    return
                }
                thread(name = "resolve-stream") {
                    try {
                        val r = DlnaCaster.resolveForPlayer(
                            url,
                            call.argument<Boolean>("legacy") == true,
                            call.argument<Boolean>("audio") == true,
                            call.argument<Int>("height") ?: 720,
                        )
                        main.post { result.success(mapOf("title" to r.first, "url" to r.second, "duration" to r.third)) }
                    } catch (e: Throwable) {
                        main.post { result.error("resolve_failed", e.message ?: "Could not open this video", null) }
                    }
                }
            }

            "enterPip" -> {
                result.success(enterPip())
            }

            "mediaThumb" -> {
                val uriText = call.argument<String>("uri") ?: ""
                kotlin.concurrent.thread(name = "media-thumb") {
                    var bytes: ByteArray? = null
                    try {
                        val bmp = MediaThumbs.load(applicationContext, uriText)
                        if (bmp != null) {
                            val out = java.io.ByteArrayOutputStream()
                            bmp.compress(android.graphics.Bitmap.CompressFormat.JPEG, 85, out)
                            bytes = out.toByteArray()
                        }
                    } catch (e: Exception) {
                        // no picture available
                    }
                    runOnUiThread { result.success(bytes) }
                }
            }

            "castAppend" -> {
                val items = call.argument<List<Map<String, Any?>>>("items").orEmpty()
                DlnaCaster.append(
                    items.map {
                        DlnaCaster.Item(
                            it["uri"] as? String ?: "",
                            it["title"] as? String ?: "",
                            it["mime"] as? String ?: "video/mp4",
                            it["stream"] as? Boolean ?: false,
                        )
                    },
                )
                result.success(null)
            }

            "pickMedia" -> {
                if (pendingMediaResult != null) {
                    result.error("busy", "File picker already open", null)
                    return
                }
                pendingMediaResult = result
                val pick = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = "*/*"
                    putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("audio/*", "video/*"))
                    putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
                }
                @Suppress("DEPRECATION")
                startActivityForResult(pick, REQUEST_MEDIA)
            }

            "consumeSharedText" -> {
                val t = pendingShared
                pendingShared = null
                result.success(t)
            }

            else -> result.notImplemented()
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == REQUEST_MEDIA) {
            val pending = pendingMediaResult ?: return
            pendingMediaResult = null
            val picked = ArrayList<Uri>()
            data?.clipData?.let { clip -> for (i in 0 until clip.itemCount) picked.add(clip.getItemAt(i).uri) }
            data?.data?.let { if (picked.isEmpty()) picked.add(it) }
            if (resultCode != RESULT_OK || picked.isEmpty()) {
                pending.success(emptyList<Map<String, Any?>>())
                return
            }
            val list = picked.map { uri ->
                try {
                    contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
                } catch (e: Exception) {
                    // a temporary grant is enough while casting
                }
                var name = uri.lastPathSegment ?: "Media"
                try {
                    contentResolver.query(uri, arrayOf(android.provider.OpenableColumns.DISPLAY_NAME), null, null, null)
                        ?.use { c -> if (c.moveToFirst()) name = c.getString(0) ?: name }
                } catch (e: Exception) {
                    // keep the fallback name
                }
                val mime = contentResolver.getType(uri) ?: "video/mp4"
                mapOf("uri" to uri.toString(), "title" to name.substringBeforeLast('.'), "mime" to mime)
            }
            pending.success(list)
            return
        }
        if (requestCode != REQUEST_FOLDER) {
            @Suppress("DEPRECATION")
            super.onActivityResult(requestCode, resultCode, data)
            return
        }
        val result = pendingFolderResult ?: return
        pendingFolderResult = null
        val uri: Uri? = data?.data
        if (resultCode != RESULT_OK || uri == null) {
            result.success(null)
            return
        }
        try {
            result.success(folders.add(uri).toMap())
        } catch (e: Exception) {
            result.error("folder_failed", e.message ?: "Could not use that folder", null)
        }
    }

    // ---- picture-in-picture (floating video window) -----------------------------------

    private fun pipAction(icon: Int, label: String, code: Int, action: String): RemoteAction =
        RemoteAction(
            Icon.createWithResource(this, icon), label, label,
            PendingIntent.getBroadcast(
                this, code,
                Intent(this, CastActionReceiver::class.java).setAction(action),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            ),
        )

    private fun pipParams(): PictureInPictureParams {
        val b = PictureInPictureParams.Builder()
            .setAspectRatio(Rational(16, 9))
            .setActions(
                listOf(
                    pipAction(R.drawable.ic_prev, "Restart", 21, PlaybackService.ACTION_WEB_PREV),
                    if (pipPlaying) pipAction(R.drawable.ic_pause, "Pause", 22, PlaybackService.ACTION_WEB_TOGGLE)
                    else pipAction(R.drawable.ic_play, "Play", 22, PlaybackService.ACTION_WEB_TOGGLE),
                    pipAction(R.drawable.ic_next, "Next", 23, PlaybackService.ACTION_WEB_NEXT),
                ),
            )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            b.setAutoEnterEnabled(pipReady)
        }
        return b.build()
    }

    private fun applyPipParams() {
        try {
            setPictureInPictureParams(pipParams())
        } catch (e: Exception) {
            // picture-in-picture is not available on this device
        }
    }

    private fun enterPip(): Boolean =
        try {
            enterPictureInPictureMode(pipParams())
        } catch (e: Exception) {
            false
        }

    private fun findWebViews(v: android.view.View, out: MutableList<android.webkit.WebView>) {
        if (v is android.webkit.WebView) out.add(v)
        if (v is android.view.ViewGroup) {
            for (i in 0 until v.childCount) findWebViews(v.getChildAt(i), out)
        }
    }

    /** A page that plays video must not be paused just because the app left the screen. */
    private fun keepWebRunning() {
        if (!keepWeb) return
        try {
            val found = ArrayList<android.webkit.WebView>()
            findWebViews(window.decorView, found)
            for (w in found) {
                w.onResume()
                w.resumeTimers()
            }
        } catch (e: Exception) {
            // best effort
        }
    }

    override fun onPause() {
        super.onPause()
        keepWebRunning()
    }

    override fun onStop() {
        super.onStop()
        keepWebRunning()
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        // Android 12+ enters by itself (auto-enter); older versions are asked here.
        if (pipReady && Build.VERSION.SDK_INT < Build.VERSION_CODES.S) enterPip()
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        DlnaCaster.emitExternal(mapOf("type" to "pip", "on" to isInPictureInPictureMode))
    }

    /** While casting, the phone's volume keys change the TV volume, like in the YouTube app. */
    override fun onKeyDown(keyCode: Int, event: android.view.KeyEvent): Boolean {
        if ((keyCode == android.view.KeyEvent.KEYCODE_VOLUME_UP || keyCode == android.view.KeyEvent.KEYCODE_VOLUME_DOWN) &&
            DlnaCaster.canControlVolume()
        ) {
            DlnaCaster.control(if (keyCode == android.view.KeyEvent.KEYCODE_VOLUME_UP) "volumeUp" else "volumeDown")
            return true
        }
        return super.onKeyDown(keyCode, event)
    }

    private fun captureShared(intent: Intent?) {
        if (intent?.action == Intent.ACTION_SEND && intent.type?.startsWith("text/") == true) {
            val text = intent.getStringExtra(Intent.EXTRA_TEXT)
            if (!text.isNullOrBlank()) pendingShared = text
            intent.action = null // do not re-read the same share after rotation
        }
    }

    private fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.POST_NOTIFICATIONS), 7)
        }
    }

    private companion object {
        const val REQUEST_FOLDER = 4201
        const val REQUEST_MEDIA = 4202
    }
}
