package com.example.piliplus.localmedia

import android.content.Context
import android.os.Handler
import android.os.Looper
import org.videolan.libvlc.interfaces.IMedia
import org.videolan.libvlc.util.MediaBrowser

/**
 * LAN discovery / browsing on top of libvlc's MediaBrowser:
 *  - automatic discovery of network shares (smb etc.)
 *  - hierarchical browsing of smb/ftp/nfs/webdav/http(s) URLs
 *
 * Results are relayed through the shared event channel as:
 *  {type:"netDiscoveryItem", item:{name,uri,isDir,...}}   (streamed)
 *  {type:"netBrowseItem", item:{...}}                     (streamed)
 *  {type:"netBrowseDone", url}
 *  {type:"netError", op, message}
 *
 * Credential prompts arrive through VlcEngine.dialogListener (Dialog API).
 * Passwords are never logged; URLs are redacted before logging.
 */
class NetBrowser(private val context: Context) {

    companion object {
        private const val TAG = "NetBrowser"

        fun redact(url: String?): String {
            if (url == null) return ""
            // scheme://user:pass@host -> scheme://user:***@host
            return url.replace(Regex("://([^/@:]+):([^@/]+)@"), "://$1:***@")
        }
    }

    private val main = Handler(Looper.getMainLooper())
    private var browser: MediaBrowser? = null
    private var emit: ((Map<String, Any?>) -> Unit)? = null

    @Volatile
    private var browseInProgress = false
    private var browseUrl = ""

    private val listener = object : MediaBrowser.EventListener {
        override fun onMediaAdded(index: Int, media: IMedia) {
            val item = mediaToMap(media) ?: return
            val type = if (browseInProgress) "netBrowseItem" else "netDiscoveryItem"
            main.post { emit?.invoke(mapOf("type" to type, "item" to item)) }
        }

        override fun onMediaRemoved(index: Int, media: IMedia) {
            val uri = runCatching { media.uri?.toString() }.getOrNull()
            main.post { emit?.invoke(mapOf("type" to "netItemRemoved", "uri" to (uri ?: ""))) }
        }

        override fun onBrowseEnd() {
            browseInProgress = false
            val url = browseUrl
            main.post { emit?.invoke(mapOf("type" to "netBrowseDone", "url" to redact(url))) }
        }
    }

    private fun mediaToMap(media: IMedia): Map<String, Any?>? {
        return try {
            val uri = media.uri?.toString() ?: return null
            val type = media.type
            val title = runCatching { media.getMeta(IMedia.Meta.Title) }.getOrNull()
            val name = if (!title.isNullOrEmpty()) title else uri.substringAfterLast('/').ifEmpty { uri }
            mapOf(
                "name" to name,
                "uri" to uri,
                // libvlc_media_type_t: 1=file, 2=directory
                "isDir" to (type == IMedia.Type.Directory),
                "type" to type,
                "durationMs" to media.duration,
            )
        } catch (t: Throwable) {
            LogCollector.e(TAG, "mediaToMap failed", t)
            null
        }
    }

    private fun ensureBrowser(): MediaBrowser {
        browser?.let { return it }
        val instance = VlcEngine.ensureInit(context)
        val b = MediaBrowser(instance, listener)
        browser = b
        return b
    }

    fun setEmitter(sink: (Map<String, Any?>) -> Unit) {
        emit = sink
    }

    fun startDiscovery(serviceName: String?) {
        try {
            browseInProgress = false
            val b = ensureBrowser()
            if (serviceName.isNullOrEmpty()) b.discoverNetworkShares()
            else b.discoverNetworkShares(serviceName)
            LogCollector.i(TAG, "discovery started (${serviceName ?: "default"})")
        } catch (t: Throwable) {
            LogCollector.e(TAG, "startDiscovery failed", t)
            main.post {
                emit?.invoke(
                    mapOf("type" to "netError", "op" to "discovery", "message" to t.toString())
                )
            }
        }
    }

    fun stopDiscovery() {
        // MediaBrowser.reset happens on the next browse/discover call.
        browseInProgress = false
    }

    fun browse(url: String) {
        try {
            browseUrl = url
            browseInProgress = true
            val b = ensureBrowser()
            b.browse(
                android.net.Uri.parse(url),
                MediaBrowser.Flag.Interact or MediaBrowser.Flag.NoSlavesAutodetect
            )
            LogCollector.i(TAG, "browsing ${redact(url)}")
        } catch (t: Throwable) {
            browseInProgress = false
            LogCollector.e(TAG, "browse failed: ${redact(url)}", t)
            main.post {
                emit?.invoke(mapOf("type" to "netError", "op" to "browse", "message" to t.toString()))
            }
        }
    }

    fun release() {
        try {
            browser?.release()
        } catch (t: Throwable) {
            LogCollector.w(TAG, "release failed: $t")
        }
        browser = null
    }
}
