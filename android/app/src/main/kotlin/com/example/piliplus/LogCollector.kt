package com.example.piliplus

import android.os.Process
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.BufferedReader
import java.io.InputStreamReader
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.regex.Pattern

/**
 * 错误日志收集器(设置 → 日志 → 导出/查看引擎日志 的数据源)。
 *
 * 两条进账:
 *  1. [add] / [e] / [w] / [i]: 代码里显式记录(带堆栈), 同时镜像到 logcat
 *     方便 adb; 抓取线程会跳过这些自有 tag, 不会产生重复。
 *  2. 后台守护线程 `logcat -v threadtime` 抓**本进程**的行, 只保留
 *     W/E/F 级别以及 VLC 引擎相关 tag(libvlc、VLC/xxx、medialibrary、mla),
 *     于是 native 崩溃前的引擎报错、`MedialibraryImpl` 的 JNI 日志都能进缓冲。
 *
 * 环形缓冲上限 [MAX_LINES] 行(进程内, 不落盘; 导出时由 Dart 侧合成文件)。
 * 之前"媒体库初始化失败"只能靠 adb 才能看到根因, 就是因为缺这一层
 * (见 docs/piliplayer.md §18)。
 *
 * MethodChannel `piliplus/log_collector`: dump(limit) / clear / push(level,tag,msg)。
 */
object LogCollector {

    private const val TAG = "LogCollector"
    private const val MAX_LINES = 4000
    private const val MAX_LINE_LEN = 2000

    private val buffer = ArrayDeque<String>()
    private val lock = Any()

    /** 显式 add() 用过的 tag: 抓取线程跳过, 避免"镜像→再抓回"重复 */
    private val ownedTags = HashSet<String>()

    @Volatile
    private var started = false

    // threadtime: "MM-DD HH:MM:SS.mmm  PID  TID LEVEL TAG: msg"
    private val linePattern: Pattern = Pattern.compile(
        "^\\d{2}-\\d{2} [\\d:.]+\\s+(\\d+)\\s+\\d+\\s+([VDIWEF])\\s+(.*)$",
    )
    private val engineTagPattern: Pattern = Pattern.compile(
        "(?i)^(vlc|libvlc|medialibrary|mla|JMedialibrary|VLC/)[\\s/:]",
    )
    private val timeFmt = SimpleDateFormat("MM-dd HH:mm:ss.SSS", Locale.US)

    /** MainActivity.configureFlutterEngine 里调用一次。 */
    fun install(messenger: BinaryMessenger) {
        startCapture()
        val channel = MethodChannel(messenger, "piliplus/log_collector")
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "dump" -> {
                    val limit = (call.argument<Number>("limit") ?: MAX_LINES).toInt()
                    result.success(dump(limit))
                }
                "clear" -> {
                    clear()
                    result.success(null)
                }
                "push" -> {
                    val level = (call.argument<String>("level") ?: "I").firstOrNull() ?: 'I'
                    val tag = call.argument<String>("tag") ?: "pili.flutter"
                    val msg = call.argument<String>("msg") ?: ""
                    add(level, tag, msg, null)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    fun e(tag: String, msg: String, t: Throwable? = null) = add('E', tag, msg, t)
    fun w(tag: String, msg: String, t: Throwable? = null) = add('W', tag, msg, t)
    fun i(tag: String, msg: String) = add('I', tag, msg, null)

    fun add(level: Char, tag: String, msg: String, t: Throwable?) {
        // SimpleDateFormat 非线程安全, 格式化放在锁内
        synchronized(lock) {
            pushLocked("${timeFmt.format(Date())} $level/$tag: $msg")
            ownedTags.add(tag)
            if (t != null) {
                pushLocked(Log.getStackTraceString(t))
            }
        }
        // 镜像到 logcat(adb 可见); 抓取线程按 ownedTags 去重
        val priority = when (level) {
            'E' -> Log.ERROR
            'W' -> Log.WARN
            else -> Log.INFO
        }
        try {
            Log.println(
                priority,
                tag,
                if (t != null) "$msg\n${Log.getStackTraceString(t)}" else msg,
            )
        } catch (_: Throwable) {
        }
    }

    fun dump(limit: Int = MAX_LINES): String = synchronized(lock) {
        val from = if (buffer.size > limit) buffer.size - limit else 0
        (from until buffer.size).joinToString("\n") { buffer[it] }
    }

    fun clear() = synchronized(lock) { buffer.clear() }

    fun lineCount(): Int = synchronized(lock) { buffer.size }

    private fun pushLocked(chunk: String) {
        for (raw in chunk.split('\n')) {
            val l = if (raw.length > MAX_LINE_LEN) raw.substring(0, MAX_LINE_LEN) + "…" else raw
            buffer.addLast(l)
        }
        while (buffer.size > MAX_LINES) {
            buffer.removeFirst()
        }
    }

    private fun startCapture() {
        if (started) return
        started = true
        val th = Thread {
            // 注意: 文件头 import 了 android.os.Process, 这里必须写全限定名
            var proc: java.lang.Process? = null
            try {
                val p = Runtime.getRuntime().exec(arrayOf("logcat", "-v", "threadtime"))
                proc = p
                val myPid = Process.myPid().toString()
                BufferedReader(InputStreamReader(p.inputStream)).use { reader ->
                    var line = reader.readLine()
                    while (line != null && started) {
                        if (interesting(line, myPid)) {
                            synchronized(lock) { pushLocked(line) }
                        }
                        line = reader.readLine()
                    }
                }
            } catch (e: Throwable) {
                // 部分定制 ROM 禁了 logcat exec; 收集器退化为"只有显式记录"
                Log.w(TAG, "logcat capture unavailable: ${e.message}")
            } finally {
                proc?.destroy()
            }
        }
        th.isDaemon = true
        th.name = "pili-logcat"
        th.start()
    }

    private fun interesting(line: String, myPid: String): Boolean {
        val m = linePattern.matcher(line)
        if (!m.matches()) return false
        if (m.group(1) != myPid) return false
        val level = m.group(2)!!
        val rest = m.group(3)!!
        if (level == "W" || level == "E" || level == "F") {
            // 自有 tag 的行由 add() 直接进缓冲, 这里跳过避免重复
            val tag = rest.substringBefore(':', rest)
            synchronized(lock) {
                if (ownedTags.contains(tag.trim())) return false
            }
            return true
        }
        return engineTagPattern.matcher(rest).find()
    }
}
