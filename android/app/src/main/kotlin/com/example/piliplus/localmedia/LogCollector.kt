package com.example.piliplus.localmedia

import android.content.Context
import android.os.Process
import java.io.File
import java.text.SimpleDateFormat
import java.util.ArrayDeque
import java.util.Date
import java.util.Locale

/**
 * Unified ring buffer + persistent file log for native diagnostics
 * (PiliPlus local module, requirement 2.6).
 *
 * Sources:
 *  - our own logcat capture of this process (includes libvlc "VLC-std" logs,
 *    linker/loader errors and the system's fatal-signal lines),
 *  - manual entries from the bridge / Dart layer,
 *  - uncaught Java exceptions (handler installed on attach).
 *
 * Every entry is also appended to a small rotating file in filesDir so that
 * diagnostics SURVIVE a process crash (the historical "init failure with no
 * way to debug" scenario must never happen again).
 */
object LogCollector {
    private const val MAX_LINES = 3000
    private const val MAX_FILE_BYTES = 768L * 1024L

    private val lock = Any()
    private val buffer = ArrayDeque<String>()
    private val timeFmt = SimpleDateFormat("MM-dd HH:mm:ss.SSS", Locale.US)

    private var logFile: File? = null

    @Volatile
    private var capturing = false
    private var thread: Thread? = null

    /** Must be called once from LocalMediaPlugin.attach (before engine use). */
    fun attach(context: Context) {
        synchronized(lock) {
            if (logFile == null) {
                try {
                    logFile = File(context.filesDir, "pili_engine.log")
                } catch (t: Throwable) {
                    // stay memory-only
                }
            }
        }
        installUncaughtHandler()
        startLogcatCapture()
        i("LogCollector", "session start (pid=${Process.myPid()})")
    }

    private var uncaughtInstalled = false

    private fun installUncaughtHandler() {
        if (uncaughtInstalled) return
        uncaughtInstalled = true
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { t, e ->
            try {
                add("F", "UncaughtException", "thread=${t.name}\n${Log.getStackTraceStringCompat(e)}")
                flushNow()
            } catch (_: Throwable) {
            }
            previous?.uncaughtException(t, e)
        }
    }

    fun add(level: String, tag: String, msg: String) {
        var line: String
        synchronized(lock) {
            line = "${timeFmt.format(Date())} $level/$tag: $msg"
            buffer.addLast(line)
            while (buffer.size > MAX_LINES) buffer.removeFirst()
        }
        appendToFile(line, flush = level != "I" && level != "D")
    }

    private fun appendToFile(line: String, flush: Boolean) {
        val f = logFile ?: return
        try {
            synchronized(lock) {
                if (f.length() > MAX_FILE_BYTES) rotate(f)
                f.appendText(line + "\n")
            }
        } catch (_: Throwable) {
        }
    }

    private fun rotate(f: File) {
        try {
            // keep the newest half
            val lines = f.readLines()
            val keep = lines.subList((lines.size / 2).coerceAtLeast(0), lines.size)
            f.writeText(keep.joinToString("\n") + "\n")
        } catch (_: Throwable) {
            try { f.delete() } catch (_: Throwable) {}
        }
    }

    private fun flushNow() {
        // appendText opens/closes per call; nothing buffered on our side.
    }

    fun e(tag: String, msg: String, t: Throwable? = null) {
        add("E", tag, if (t != null) "$msg\n${Log.getStackTraceStringCompat(t)}" else msg)
    }

    fun w(tag: String, msg: String) = add("W", tag, msg)
    fun i(tag: String, msg: String) = add("I", tag, msg)

    /**
     * Snapshot for the UI/export: the persistent file when available (it
     * contains pre-crash lines from earlier sessions), otherwise memory.
     */
    fun snapshot(): List<String> {
        val f = logFile
        if (f != null && f.exists()) {
            try {
                val lines = f.readLines()
                if (lines.size > MAX_LINES) return lines.subList(lines.size - MAX_LINES, lines.size)
                if (lines.isNotEmpty()) return lines
            } catch (_: Throwable) {
            }
        }
        synchronized(lock) { return buffer.toList() }
    }

    fun clear() {
        synchronized(lock) {
            buffer.clear()
            try { logFile?.writeText("") } catch (_: Throwable) {}
        }
    }

    /**
     * Reads this process's own logcat output (no permission needed).
     * Started as early as possible so that loader/linker errors and fatal
     * signals around libvlc initialization are captured.
     */
    fun startLogcatCapture() {
        if (capturing) return
        capturing = true
        thread = Thread({
            var proc: java.lang.Process? = null
            try {
                // Only clear on the very first session so restarts keep history.
                proc = Runtime.getRuntime().exec(
                    arrayOf(
                        "logcat", "-v", "threadtime",
                        "--pid=${Process.myPid()}"
                    )
                )
                val reader = proc.inputStream.bufferedReader()
                val keep = Regex("""\s([EWF])/|VLC|libvlc|libc\s*:|DEBUG|AndroidRuntime|linker|omx|c2\.|ACodec""")
                while (capturing) {
                    val line = reader.readLine() ?: break
                    if (keep.containsMatchIn(line)) {
                        val f = logFile
                        synchronized(lock) {
                            buffer.addLast(line)
                            while (buffer.size > MAX_LINES) buffer.removeFirst()
                        }
                        if (f != null) {
                            try { f.appendText(line + "\n") } catch (_: Throwable) {}
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

    /** Small helper so we don't depend on android.util.Log import clashes. */
    private object Log {
        fun getStackTraceStringCompat(t: Throwable): String =
            t.stackTraceToString()
    }
}
