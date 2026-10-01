package com.example.piliplus.localmedia

import android.os.Process
import java.text.SimpleDateFormat
import java.util.ArrayDeque
import java.util.Date
import java.util.Locale

/**
 * Unified ring buffer for native-side diagnostics (PiliPlus local module).
 *
 * Two sources feed it:
 *  - our own logcat capture of this process (which includes libvlc's
 *    "VLC-std"/"libvlc" logs and any Android runtime warnings), and
 *  - manual entries from the bridge / Dart layer.
 *
 * The buffer is intentionally small and in-memory; export happens through
 * the Dart side (see the diagnostic export page).
 */
object LogCollector {
    private const val MAX_LINES = 3000

    private val lock = Any()
    private val buffer = ArrayDeque<String>()
    private val timeFmt = SimpleDateFormat("MM-dd HH:mm:ss.SSS", Locale.US)

    @Volatile
    private var capturing = false
    private var thread: Thread? = null

    fun add(level: String, tag: String, msg: String) {
        synchronized(lock) {
            val line = "${timeFmt.format(Date())} $level/$tag: $msg"
            buffer.addLast(line)
            while (buffer.size > MAX_LINES) buffer.removeFirst()
        }
    }

    fun e(tag: String, msg: String, t: Throwable? = null) {
        add("E", tag, if (t != null) "$msg\n${t.stackTraceToString()}" else msg)
    }

    fun w(tag: String, msg: String) = add("W", tag, msg)
    fun i(tag: String, msg: String) = add("I", tag, msg)

    fun snapshot(): List<String> = synchronized(lock) { buffer.toList() }

    fun clear() = synchronized(lock) { buffer.clear() }

    /**
     * Starts reading this process's own logcat output. Reading our own pid
     * requires no permission on any Android version.
     */
    fun startLogcatCapture() {
        if (capturing) return
        capturing = true
        thread = Thread({
            var proc: Process? = null
            try {
                // Flush stale logs, then follow.
                Runtime.getRuntime().exec(arrayOf("logcat", "-c")).waitFor()
                proc = Runtime.getRuntime().exec(
                    arrayOf(
                        "logcat", "-v", "threadtime",
                        "--pid=${Process.myPid()}"
                    )
                )
                val reader = proc.inputStream.bufferedReader()
                // Keep only warnings/errors and everything from VLC-related
                // tags, so the ring buffer stays useful and bounded.
                val keep = Regex("""\s([EWF])/|VLC|libvlc|mediaplayer|MediaStore|omx|c2\.|ACodec""")
                while (capturing) {
                    val line = reader.readLine() ?: break
                    if (keep.containsMatchIn(line)) {
                        synchronized(lock) {
                            buffer.addLast(line)
                            while (buffer.size > MAX_LINES) buffer.removeFirst()
                        }
                    }
                }
            } catch (t: Throwable) {
                e("LogCollector", "logcat capture failed", t)
            } finally {
                try { proc?.destroy() } catch (_: Exception) {}
            }
        }, "pili-logcat").apply { isDaemon = true; start() }
    }

    fun stopLogcatCapture() {
        capturing = false
        thread?.interrupt()
        thread = null
    }
}
