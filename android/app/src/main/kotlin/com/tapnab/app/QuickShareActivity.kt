package com.tapnab.app

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.CheckBox
import android.widget.FrameLayout
import android.widget.HorizontalScrollView
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast

/**
 * The "Share -> Tapnab" pop-up. It slides over YouTube (or any app) as a small
 * sheet, so a link can be downloaded in two taps without leaving the app you
 * were in. It talks straight to [DownloadManager]; Flutter does not need to be
 * running.
 */
class QuickShareActivity : Activity() {

    private class Q(val value: Int, val label: String)

    private val audio = listOf(
        Q(64, "64"), Q(96, "96"), Q(128, "128"), Q(192, "192"), Q(256, "256"), Q(320, "320 kbps"),
    )
    private val video = listOf(
        Q(144, "144p"), Q(240, "240p"), Q(360, "360p"), Q(480, "480p"), Q(720, "720p HD"),
        Q(1080, "1080p"), Q(1440, "2K"), Q(2160, "4K"), Q(0, "Best"),
    )

    private lateinit var urls: List<String>
    private lateinit var kind: String
    private var quality = 0
    private var wholePlaylist = false

    private lateinit var qualityRow: LinearLayout
    private lateinit var mp3Button: Button
    private lateinit var mp4Button: Button

    private var dark = false
    private val coral = Color.parseColor("#FF5A5F")
    private val violet = Color.parseColor("#7B2FF7")

    private val card get() = if (dark) Color.parseColor("#1F1B26") else Color.parseColor("#FFFFFF")
    private val ink get() = if (dark) Color.parseColor("#EDE7F6") else Color.parseColor("#1B1B1F")
    private val sub get() = if (dark) Color.parseColor("#B7AFC4") else Color.parseColor("#5F5B6B")
    private val chipOff get() = if (dark) Color.parseColor("#34303D") else Color.parseColor("#EEE9F5")

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val shared = intent?.getStringExtra(Intent.EXTRA_TEXT).orEmpty()
        urls = Regex("""https?://[^\s<>"']+""").findAll(shared).map { it.value.trimEnd('.', ',', ')') }.distinct().toList()
        if (urls.isEmpty()) {
            Toast.makeText(this, "No link found in what was shared", Toast.LENGTH_LONG).show()
            finish()
            return
        }

        dark = when (AppSettings.themeMode(this)) {
            "dark" -> true
            "light" -> false
            else -> (resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES
        }

        val quick = getSharedPreferences("tapnab_quick", Context.MODE_PRIVATE)
        kind = quick.getString("kind", null) ?: AppSettings.kind(this)
        quality = if (quick.contains("q_$kind")) quick.getInt("q_$kind", 0) else AppSettings.quality(this, kind)
        val hasList = urls.any { it.contains("list=") }
        wholePlaylist = hasList && AppSettings.playlistMode(this)

        setContentView(buildUi(hasList))
    }

    // ---- UI -----------------------------------------------------------------

    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()

    private fun round(color: Int, radius: Int) = GradientDrawable().apply {
        setColor(color)
        cornerRadius = dp(radius).toFloat()
    }

    private fun text(s: String, size: Float, color: Int, bold: Boolean = false) = TextView(this).apply {
        text = s
        textSize = size
        setTextColor(color)
        if (bold) setTypeface(typeface, Typeface.BOLD)
    }

    private fun buildUi(hasList: Boolean): View {
        val root = FrameLayout(this).apply {
            setBackgroundColor(Color.parseColor("#99000000"))
            setOnClickListener { finish() }
        }

        val sheet = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(18), dp(20), dp(20))
            background = GradientDrawable().apply {
                setColor(card)
                cornerRadii = floatArrayOf(
                    dp(28).toFloat(), dp(28).toFloat(), dp(28).toFloat(), dp(28).toFloat(), 0f, 0f, 0f, 0f,
                )
            }
            isClickable = true // swallow taps so the scrim does not close the sheet
        }

        val handle = View(this).apply { background = round(chipOff, 3) }
        sheet.addView(handle, LinearLayout.LayoutParams(dp(40), dp(5)).apply {
            gravity = Gravity.CENTER_HORIZONTAL
            bottomMargin = dp(14)
        })

        sheet.addView(text("Tapnab", 20f, ink, bold = true))
        val what = if (urls.size > 1) "${urls.size} links" else shortUrl(urls[0])
        sheet.addView(text(what, 13f, sub).apply { maxLines = 1; ellipsize = android.text.TextUtils.TruncateAt.MIDDLE })

        // MP3 | MP4
        val kinds = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        mp3Button = pill("MP3  Audio") { setKind("mp3") }
        mp4Button = pill("MP4  Video") { setKind("mp4") }
        kinds.addView(mp3Button, LinearLayout.LayoutParams(0, dp(46), 1f).apply { rightMargin = dp(6) })
        kinds.addView(mp4Button, LinearLayout.LayoutParams(0, dp(46), 1f).apply { leftMargin = dp(6) })
        sheet.addView(kinds, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
            topMargin = dp(16)
        })

        // Quality, lowest to highest
        sheet.addView(text("Quality", 12f, sub).apply { setPadding(0, dp(14), 0, dp(6)) })
        qualityRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        sheet.addView(HorizontalScrollView(this).apply {
            isHorizontalScrollBarEnabled = false
            addView(qualityRow)
        })

        if (hasList) {
            sheet.addView(CheckBox(this).apply {
                text = "Download the whole playlist"
                setTextColor(ink)
                isChecked = wholePlaylist
                setOnCheckedChangeListener { _, checked -> wholePlaylist = checked }
            }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
                topMargin = dp(8)
            })
        }

        sheet.addView(text("Saving to: ${destinationName()}", 12f, sub).apply { setPadding(0, dp(12), 0, dp(14)) })

        val go = Button(this).apply {
            text = if (urls.size > 1) "Download ${urls.size} links" else "Download"
            isAllCaps = false
            textSize = 16f
            setTextColor(Color.WHITE)
            setTypeface(typeface, Typeface.BOLD)
            background = GradientDrawable(
                GradientDrawable.Orientation.LEFT_RIGHT, intArrayOf(coral, violet),
            ).apply { cornerRadius = dp(26).toFloat() }
            setOnClickListener { startDownloads() }
        }
        sheet.addView(go, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(52)))

        val more = Button(this).apply {
            text = "Open Tapnab for more options"
            isAllCaps = false
            setTextColor(violetOnCard())
            background = null
            setOnClickListener { openApp() }
        }
        sheet.addView(more, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(46)).apply {
            topMargin = dp(4)
        })

        root.addView(sheet, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.BOTTOM,
        ))

        refresh()
        return root
    }

    private fun violetOnCard() = if (dark) Color.parseColor("#C9A8FF") else violet

    private fun pill(label: String, onClick: () -> Unit) = Button(this).apply {
        text = label
        isAllCaps = false
        textSize = 14f
        setOnClickListener { onClick() }
    }

    private fun styleChoice(b: Button, selected: Boolean) {
        b.background = round(if (selected) violet else chipOff, 23)
        b.setTextColor(if (selected) Color.WHITE else ink)
    }

    private fun setKind(k: String) {
        if (k == kind) return
        kind = k
        quality = getSharedPreferences("tapnab_quick", Context.MODE_PRIVATE)
            .let { if (it.contains("q_$k")) it.getInt("q_$k", 0) else AppSettings.quality(this, k) }
        refresh()
    }

    private fun refresh() {
        styleChoice(mp3Button, kind == "mp3")
        styleChoice(mp4Button, kind == "mp4")
        qualityRow.removeAllViews()
        val options = if (kind == "mp3") audio else video
        // Fall back to a sensible option if the remembered one is not in the list.
        if (options.none { it.value == quality }) quality = if (kind == "mp3") 192 else 720
        for (o in options) {
            val chip = Button(this).apply {
                text = o.label
                isAllCaps = false
                textSize = 13f
                minWidth = 0
                minimumWidth = 0
                setPadding(dp(14), 0, dp(14), 0)
                setOnClickListener { quality = o.value; refresh() }
            }
            styleChoice(chip, o.value == quality)
            qualityRow.addView(chip, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, dp(40)).apply {
                rightMargin = dp(8)
            })
        }
    }

    // ---- actions ------------------------------------------------------------

    private fun startDownloads() {
        getSharedPreferences("tapnab_quick", Context.MODE_PRIVATE).edit()
            .putString("kind", kind)
            .putInt("q_$kind", quality)
            .apply()

        val folder = AppSettings.folderUri(this)
        val stamp = System.currentTimeMillis()
        urls.forEachIndexed { i, url ->
            DownloadManager.enqueue(
                this,
                DownloadManager.Task(
                    id = "q-$stamp-$i",
                    url = url,
                    kind = kind,
                    quality = quality,
                    playlist = wholePlaylist && url.contains("list="),
                    folderUri = folder,
                ),
            )
        }
        Toast.makeText(this, "Download started. See progress in Tapnab.", Toast.LENGTH_SHORT).show()
        finish()
    }

    private fun openApp() {
        val open = Intent(this, MainActivity::class.java).apply {
            action = Intent.ACTION_SEND
            type = "text/plain"
            putExtra(Intent.EXTRA_TEXT, intent?.getStringExtra(Intent.EXTRA_TEXT))
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }
        startActivity(open)
        finish()
    }

    private fun destinationName(): String {
        val uri = AppSettings.folderUri(this)
            ?: return if (kind == "mp3") "Music/Tapnab" else "Movies/Tapnab"
        return FolderStore(this).list().firstOrNull { it.uri == uri }?.name
            ?: if (kind == "mp3") "Music/Tapnab" else "Movies/Tapnab"
    }

    private fun shortUrl(u: String) = u.removePrefix("https://").removePrefix("http://").removePrefix("www.")
}
