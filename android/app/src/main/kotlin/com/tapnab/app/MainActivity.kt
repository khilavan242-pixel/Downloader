package com.tapnab.app

import android.Manifest
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
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
            }

            override fun onCancel(arguments: Any?) {
                eventSink = null
                DownloadManager.listener = null
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
    }
}
