package com.tapnab.app

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import androidx.documentfile.provider.DocumentFile
import org.json.JSONArray
import org.json.JSONObject

/**
 * Remembers the folders the user picked with the system folder picker
 * (Storage Access Framework) so they can be re-used, Acode style.
 *
 * The permission grant itself is persisted by Android; this class only keeps
 * the display names and drops entries whose grant has been revoked (for
 * example when a pendrive was formatted or the folder was deleted).
 */
class FolderStore(private val context: Context) {

    private val prefs = context.getSharedPreferences("tapnab_folders", Context.MODE_PRIVATE)

    data class Folder(val uri: String, val name: String, val location: String) {
        fun toMap(): Map<String, String> = mapOf("uri" to uri, "name" to name, "location" to location)
    }

    /** Takes the persistable permission for [treeUri] and stores it. */
    fun add(treeUri: Uri): Folder {
        context.contentResolver.takePersistableUriPermission(
            treeUri,
            Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
        )
        val folder = describe(treeUri)
        val list = load().filterNot { it.uri == folder.uri } + folder
        save(list)
        return folder
    }

    fun remove(uri: String) {
        try {
            context.contentResolver.releasePersistableUriPermission(
                Uri.parse(uri),
                Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
            )
        } catch (e: Exception) {
            // Already released.
        }
        save(load().filterNot { it.uri == uri })
    }

    /** Folders whose permission is still granted. Stale entries are pruned. */
    fun list(): List<Folder> {
        val granted = context.contentResolver.persistedUriPermissions
            .filter { it.isWritePermission }
            .map { it.uri.toString() }
            .toSet()
        val all = load()
        val valid = all.filter { it.uri in granted }
        if (valid.size != all.size) save(valid)
        return valid
    }

    private fun describe(treeUri: Uri): Folder {
        val doc = DocumentFile.fromTreeUri(context, treeUri)
        val name = doc?.name ?: "Folder"
        val docId = DocumentsContract.getTreeDocumentId(treeUri) // e.g. "primary:Documents/Homework" or "1A2B-3C4D:Music"
        val volume = docId.substringBefore(':')
        val path = docId.substringAfter(':', "")
        val parent = path.substringBeforeLast('/', "")
        val volumeLabel = if (volume == "primary") "primary" else "USB / SD ($volume)"
        val location = if (parent.isEmpty()) volumeLabel else "$volumeLabel/$parent"
        return Folder(treeUri.toString(), name, location)
    }

    private fun load(): List<Folder> {
        val raw = prefs.getString(KEY, null) ?: return emptyList()
        return try {
            val arr = JSONArray(raw)
            (0 until arr.length()).map {
                val o = arr.getJSONObject(it)
                Folder(o.getString("uri"), o.getString("name"), o.optString("location"))
            }
        } catch (e: Exception) {
            emptyList()
        }
    }

    private fun save(list: List<Folder>) {
        val arr = JSONArray()
        list.forEach {
            arr.put(JSONObject().put("uri", it.uri).put("name", it.name).put("location", it.location))
        }
        prefs.edit().putString(KEY, arr.toString()).apply()
    }

    private companion object {
        const val KEY = "folders"
    }
}
