package com.tapnab.app

/**
 * Turns noisy YouTube titles into tidy file names.
 *
 * yt-dlp's `--windows-filenames` swaps characters such as `|` and `:` for their
 * full-width look-alikes, so those are mapped back before cleaning.
 *
 * Styles:
 *  * `original` - the name exactly as yt-dlp produced it
 *  * `clean`    - removes "(Official Video)" style tags and the "| Channel" tail
 *  * `short`    - `clean`, cut to about 40 characters
 */
object NameCleaner {

    private const val FULL_BAR = "｜"   // full-width vertical bar
    private const val FULL_COLON = "：" // full-width colon

    private val bracketed = Regex("""[\(\[]([^\)\]]*)[\)\]]""")

    private val noise = Regex(
        """^\s*(official|lyric|lyrics|audio|video|music video|full song|full video|full audio|hd|4k|hq|""" +
            """visuali[sz]er|remaster|remastered|with lyrics|new song|new video)\b.*$""",
        RegexOption.IGNORE_CASE,
    )

    private val spaces = Regex("""\s+""")

    fun apply(base: String, style: String): String {
        if (style == "original") return base
        var s = base.replace(FULL_BAR, "|").replace(FULL_COLON, ":")

        s = bracketed.replace(s) { m -> if (noise.matches(m.groupValues[1])) "" else m.value }

        // "Song - Artist | Official Video | Channel" -> "Song - Artist"
        val head = s.split('|').map { it.trim() }.firstOrNull { it.isNotEmpty() }
        if (head != null) s = head

        s = s.replace(":", " -")
            .replace("\\", "-").replace("/", "-")
            .replace("?", "").replace("*", "").replace("\"", "'")
            .replace("<", "").replace(">", "")
        s = spaces.replace(s, " ").trim().trim('-', '.', ' ')

        if (style == "short" && s.length > 40) {
            val cut = s.substring(0, 40)
            val space = cut.lastIndexOf(' ')
            s = (if (space >= 20) cut.substring(0, space) else cut).trim().trim('-', ' ')
        }
        if (s.length > 120) s = s.substring(0, 120).trim()
        return s.ifBlank { base }
    }

    /** A safe folder name for a playlist title. */
    fun folderName(title: String): String {
        val cleaned = apply(title, "clean").ifBlank { "Playlist" }
        return if (cleaned.length > 60) cleaned.substring(0, 60).trim() else cleaned
    }
}
