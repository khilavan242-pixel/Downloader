package com.tapnab.app

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Environment
import android.provider.MediaStore
import androidx.documentfile.provider.DocumentFile
import java.io.File

/**
 * Moves a finished file from the private cache to its final home:
 *  * a folder the user picked (any storage, including USB pendrives), or
 *  * MediaStore `Music/Tapnab` / `Movies/Tapnab`, so it shows up in music and
 *    gallery apps without any storage permission.
 *
 * With a [subfolder] (used for playlists) the file goes into a sub-directory
 * of either location.
 */
object FileSaver {

    /**
     * @property label human readable destination, e.g. `Music/Tapnab` or the folder name
     * @property uri content:// address of the saved file (used to play, share, delete)
     */
    data class Saved(val label: String, val uri: Uri, val size: Long)

    fun save(
        context: Context,
        source: File,
        isAudio: Boolean,
        folderUri: String?,
        displayName: String = source.name,
        subfolder: String? = null,
    ): Saved {
        val mime = mimeFor(source)
        return if (folderUri != null) {
            saveToTree(context, source, mime, Uri.parse(folderUri), displayName, subfolder)
        } else {
            saveToMediaStore(context, source, mime, isAudio, displayName, subfolder)
        }
    }

    private fun saveToTree(
        context: Context,
        source: File,
        mime: String,
        treeUri: Uri,
        displayName: String,
        subfolder: String?,
    ): Saved {
        val root = DocumentFile.fromTreeUri(context, treeUri)
        if (root == null || !root.exists() || !root.canWrite()) {
            throw IllegalStateException("The selected folder is no longer available. Pick it again.")
        }
        var dir: DocumentFile = root
        if (!subfolder.isNullOrBlank()) {
            dir = root.findFile(subfolder)?.takeIf { it.isDirectory }
                ?: root.createDirectory(subfolder)
                ?: throw IllegalStateException("Could not create the folder \"$subfolder\" in ${root.name}.")
        }
        val name = uniqueName(displayName) { dir.findFile(it) != null }
        val target = dir.createFile(mime, name)
            ?: throw IllegalStateException("Could not create a file in ${dir.name}. Is the drive full or read-only?")
        try {
            context.contentResolver.openOutputStream(target.uri, "w")!!.use { out ->
                source.inputStream().use { it.copyTo(out, 256 * 1024) }
            }
        } catch (e: Exception) {
            target.delete()
            throw e
        }
        val label = if (subfolder.isNullOrBlank()) root.name ?: "selected folder" else "${root.name ?: "folder"}/$subfolder"
        return Saved(label, target.uri, source.length())
    }

    private fun saveToMediaStore(
        context: Context,
        source: File,
        mime: String,
        isAudio: Boolean,
        displayName: String,
        subfolder: String?,
    ): Saved {
        val collection = if (isAudio) {
            MediaStore.Audio.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        } else {
            MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        }
        val root = if (isAudio) Environment.DIRECTORY_MUSIC else Environment.DIRECTORY_MOVIES
        val relative = if (subfolder.isNullOrBlank()) "$root/Tapnab" else "$root/Tapnab/$subfolder"
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, displayName)
            put(MediaStore.MediaColumns.MIME_TYPE, mime)
            put(MediaStore.MediaColumns.RELATIVE_PATH, relative)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val resolver = context.contentResolver
        // MediaStore renames on clash by itself ("name (1).mp3").
        val uri = resolver.insert(collection, values)
            ?: throw IllegalStateException("Could not create a file in $relative")
        try {
            resolver.openOutputStream(uri, "w")!!.use { out ->
                source.inputStream().use { it.copyTo(out, 256 * 1024) }
            }
            resolver.update(uri, ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }, null, null)
        } catch (e: Exception) {
            resolver.delete(uri, null, null)
            throw e
        }
        return Saved(relative, uri, source.length())
    }

    private fun mimeFor(file: File): String = when (file.extension.lowercase()) {
        "mp3" -> "audio/mpeg"
        "m4a" -> "audio/mp4"
        "mp4" -> "video/mp4"
        "webm" -> "video/webm"
        "mkv" -> "video/x-matroska"
        else -> "application/octet-stream"
    }

    /** "Song.mp3" -> "Song (1).mp3" while [exists] says the name is taken. */
    private fun uniqueName(name: String, exists: (String) -> Boolean): String {
        if (!exists(name)) return name
        val base = name.substringBeforeLast('.', name)
        val ext = name.substringAfterLast('.', "")
        var i = 1
        while (true) {
            val candidate = if (ext.isEmpty()) "$base ($i)" else "$base ($i).$ext"
            if (!exists(candidate)) return candidate
            i++
        }
    }
}
