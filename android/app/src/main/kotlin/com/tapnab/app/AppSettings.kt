package com.tapnab.app

import android.content.Context
import android.content.SharedPreferences

/**
 * Read-only view of the settings the Flutter side saves. Flutter's
 * shared_preferences plugin writes into the `FlutterSharedPreferences` file with
 * every key prefixed by `flutter.` (ints are stored as Long, so they are read
 * through Number).
 */
object AppSettings {

    private fun prefs(c: Context): SharedPreferences =
        c.applicationContext.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)

    private fun raw(c: Context, key: String): Any? = prefs(c).all["flutter.$key"]

    private fun string(c: Context, key: String, def: String?): String? = (raw(c, key) as? String) ?: def
    private fun bool(c: Context, key: String, def: Boolean): Boolean = (raw(c, key) as? Boolean) ?: def
    private fun int(c: Context, key: String, def: Int): Int = (raw(c, key) as? Number)?.toInt() ?: def

    /** original | clean | short */
    fun nameStyle(c: Context): String = string(c, "name_style", "clean") ?: "clean"

    fun coverArt(c: Context): Boolean = bool(c, "cover_art", true)
    fun playlistFolders(c: Context): Boolean = bool(c, "playlist_folders", true)
    fun wifiOnly(c: Context): Boolean = bool(c, "wifi_only", false)
    fun autoUpdate(c: Context): Boolean = bool(c, "auto_update", true)
    fun parallel(c: Context): Int = int(c, "parallel", 2).coerceIn(1, 4)

    /** system | light | dark */
    fun themeMode(c: Context): String = string(c, "theme_mode", "system") ?: "system"

    // ---- last choices made on the Home page (used as defaults by the share pop-up)

    fun kind(c: Context): String = if (string(c, "kind", "mp3") == "mp4") "mp4" else "mp3"

    fun quality(c: Context, kind: String): Int {
        val key = string(c, if (kind == "mp3") "audio_quality" else "video_quality", null)
        val value = key?.substringAfter(':', "")?.toIntOrNull()
        return if (key != null && key.startsWith("$kind:") && value != null) {
            value
        } else if (kind == "mp3") {
            192
        } else {
            720
        }
    }

    fun folderUri(c: Context): String? = string(c, "selected_folder_uri", null)
    fun playlistMode(c: Context): Boolean = bool(c, "playlist_mode", false)
}
