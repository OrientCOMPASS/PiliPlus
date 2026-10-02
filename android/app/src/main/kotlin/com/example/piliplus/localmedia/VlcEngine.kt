package com.example.piliplus.localmedia

import android.content.Context
import android.os.Handler
import android.os.Looper
import org.videolan.libvlc.Dialog
import org.videolan.libvlc.LibVLC
import org.videolan.libvlc.Media
import org.videolan.libvlc.MediaPlayer

/**
 * Singleton holder for the libvlc instance used by the local module.
 *
 * Kept separate from any B-site playback stack (media_kit), so that local /
 * LAN playback never triggers network code paths belonging to the site API.
 */
object VlcEngine {
    private const val TAG = "VlcEngine"

    @Volatile
    var libVlc: LibVLC? = null
        private set

    @Volatile
    var lastInitError: String? = null
        private set

    /** Relay for libvlc dialogs (SMB/WebDAV credentials, errors). */
    var dialogListener: DialogListener? = null

    private val main = Handler(Looper.getMainLooper())

    interface DialogListener {
        fun onLogin(dialog: Dialog.LoginDialog, id: Int)
        fun onError(title: String, text: String)
        fun onProgress(dialog: Dialog.ProgressDialog, id: Int)
    }

    private val dialogs = HashMap<Int, Dialog>()
    private var nextDialogId = 1

    @Synchronized
    fun ensureInit(context: Context): LibVLC {
        libVlc?.let { return it }
        lastInitError = null

        // CRITICAL: org.videolan.libvlc.LibVLC.loadLibraries() calls
        // System.exit(1) when a native library fails to load — a silent
        // process death with zero diagnostics. We preload the libraries
        // ourselves first so a failure becomes a catchable error with the
        // real linker message preserved in the log.
        val preloadError = preloadNativeLibs()
        if (preloadError != null) {
            lastInitError = "native library load failed: $preloadError"
            throw RuntimeException(lastInitError)
        }

        try {
            val options = ArrayList<String>()
            // The app draws its own OSD/controls; keep libvlc quiet on screen.
            options.add("--no-osd")
            options.add("--no-video-title-show")
            // Reasonable default for LAN playback; per-media options may
            // override. Never touches https handling (no downgrade anywhere).
            options.add("--network-caching=2000")
            LogCollector.i(TAG, "LibVLC ctor begin")
            val instance = LibVLC(context.applicationContext, options)
            LogCollector.i(TAG, "LibVLC ctor ok")
            Dialog.setCallbacks(instance, object : Dialog.Callbacks {
                override fun onDisplay(dialog: Dialog.ErrorMessage) {
                    main.post { handleDialog(dialog) }
                }

                override fun onDisplay(dialog: Dialog.LoginDialog) {
                    main.post { handleDialog(dialog) }
                }

                override fun onDisplay(dialog: Dialog.QuestionDialog) {
                    main.post { handleDialog(dialog) }
                }

                override fun onDisplay(dialog: Dialog.ProgressDialog) {
                    main.post { handleDialog(dialog) }
                }

                override fun onCanceled(dialog: Dialog) {
                    // nothing to relay
                }

                override fun onProgressUpdate(dialog: Dialog.ProgressDialog) {
                    // progress ticks are not relayed (would spam the UI)
                }
            })
            libVlc = instance
            LogCollector.i(TAG, "libvlc initialized: ${runCatching { LibVLC.version() }.getOrDefault("?")}, vrVersion=${vrVersion()}")
            return instance
        } catch (t: Throwable) {
            lastInitError = t.toString()
            LogCollector.e(TAG, "libvlc init failed", t)
            throw t
        }
    }

    /**
     * Loads c++_shared/vlc/vlcjni with per-library error capture.
     * Returns null on success, or a diagnostic string on failure.
     * Once loaded here, LibVLC.loadLibraries() becomes a silent no-op
     * (System.loadLibrary of an already-loaded library returns quietly).
     */
    private fun preloadNativeLibs(): String? {
        val results = ArrayList<String>()
        for (name in listOf("c++_shared", "vlc", "vlcjni")) {
            try {
                System.loadLibrary(name)
                results.add("$name=ok")
            } catch (t: Throwable) {
                results.add("$name=FAIL(${t.javaClass.simpleName}: ${t.message})")
                LogCollector.e(TAG, "System.loadLibrary($name) failed", t)
                if (name != "c++_shared") {
                    // Fatal for engine use; do NOT touch LibVLC (System.exit).
                    return results.joinToString("; ")
                }
            }
        }
        LogCollector.i(TAG, "native preload: ${results.joinToString("; ")}")
        return null
    }

    private fun handleDialog(dialog: Dialog) {
        val listener = dialogListener
        val id = synchronized(dialogs) {
            val id = nextDialogId++
            dialogs[id] = dialog
            id
        }
        when (dialog) {
            is Dialog.LoginDialog -> listener?.onLogin(dialog, id)
                ?: dialog.dismiss()
            is Dialog.ErrorMessage -> {
                listener?.onError(dialog.title ?: "VLC", dialog.text ?: "")
                dialog.dismiss()
            }
            is Dialog.ProgressDialog -> listener?.onProgress(dialog, id)
                ?: dialog.dismiss()
            else -> dialog.dismiss()
        }
    }

    fun dialogById(id: Int): Dialog? = synchronized(dialogs) { dialogs[id] }

    fun removeDialog(id: Int) {
        synchronized(dialogs) { dialogs.remove(id) }
    }

    /**
     * VR extension capability of the *running* engine:
     *  >0 -> PiliPlus patched libvlc; 0 -> stock libvlc (VR unavailable,
     * the UI must say so explicitly).
     */
    fun vrVersion(): Int {
        val instance = libVlc ?: return 0
        var probe: MediaPlayer? = null
        return try {
            probe = MediaPlayer(instance)
            VlcCompat.getVrVersion(probe)
        } catch (t: Throwable) {
            LogCollector.w(TAG, "vr version probe failed: $t")
            0
        } finally {
            try { probe?.release() } catch (_: Throwable) {}
        }
    }

    fun buildMedia(context: Context, uri: String, options: List<String>): Media {
        val instance = ensureInit(context)
        val media = Media(instance, android.net.Uri.parse(uri))
        for (o in options) media.addOption(o)
        return media
    }

    @Synchronized
    fun release() {
        try {
            libVlc?.release()
        } catch (t: Throwable) {
            LogCollector.e(TAG, "release failed", t)
        }
        libVlc = null
        synchronized(dialogs) { dialogs.clear() }
    }
}
