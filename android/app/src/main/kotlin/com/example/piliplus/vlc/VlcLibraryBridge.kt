package com.example.piliplus.vlc

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.videolan.medialibrary.MedialibraryImpl
import org.videolan.medialibrary.interfaces.Medialibrary
import org.videolan.medialibrary.interfaces.media.MediaWrapper
import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * VLC 媒体库(libmedialibrary)的 Flutter 桥(MethodChannel `piliplus/vlc_library`)。
 *
 * 与 VLC 安卓端同一套索引引擎: 自动扫描存储卷、按文件元数据建库、
 * 记忆每个媒体的续播位置([setLastTime])与播放历史。
 *
 * 所有查询都在后台线程执行(libml 是 JNI 同步调用), 结果 post 回主线程。
 */
class VlcLibraryBridge(
    private val context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "piliplus/vlc_library"
        private const val TAG = "VlcLibraryBridge"
    }

    private val channel = MethodChannel(messenger, CHANNEL)
    private val main = Handler(Looper.getMainLooper())
    private val worker: ExecutorService = Executors.newSingleThreadExecutor()

    @Volatile
    private var ml: MedialibraryImpl? = null
    private var disposed = false

    private val readyListener = object : Medialibrary.OnMedialibraryReadyListener {
        override fun onMedialibraryReady() {
            emit("onReady", mapOf("ok" to true))
        }

        override fun onMedialibraryIdle() {
            emit("onIdle", null)
        }
    }

    init {
        channel.setMethodCallHandler(this)
    }

    fun dispose() {
        if (disposed) return
        disposed = true
        channel.setMethodCallHandler(null)
        worker.execute {
            try {
                // libml 没有显式 release: 停后台任务 + 摘监听, native 资源由
                // finalize 兜底(dispose 只在引擎销毁时发生)
                ml?.removeOnMedialibraryReadyListener(readyListener)
                ml?.pauseBackgroundOperations()
            } catch (_: Throwable) {}
            ml = null
        }
        worker.shutdown()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "init" -> worker.execute {
                val reply = try {
                    var inst = ml
                    if (inst == null) {
                        inst = MedialibraryImpl()
                        val status = inst.init(context)
                        inst.addOnMedialibraryReadyListener(readyListener)
                        inst.start()
                        for (root in storageRoots()) {
                            try {
                                inst.banFolder(root + "/Android")
                            } catch (_: Throwable) {}
                            inst.discover(root)
                        }
                        ml = inst
                        mapOf("status" to status, "roots" to storageRoots())
                    } else {
                        mapOf("status" to 0, "roots" to storageRoots())
                    }
                } catch (e: Throwable) {
                    Log.e(TAG, "init failed", e)
                    mapOf("error" to "${e.message}")
                }
                main.post { result.success(reply) }
            }

            "videos" -> worker.execute {
                val list = try {
                    (ml?.getVideos() ?: emptyArray()).map { describe(it) }
                } catch (e: Throwable) {
                    Log.w(TAG, "videos: ${e.message}")
                    emptyList()
                }
                main.post { result.success(list) }
            }

            "history" -> worker.execute {
                val list = try {
                    (ml?.history(Medialibrary.HISTORY_TYPE_LOCAL) ?: emptyArray()).map { describe(it) }
                } catch (e: Throwable) {
                    Log.w(TAG, "history: ${e.message}")
                    emptyList()
                }
                main.post { result.success(list) }
            }

            // 续播进度: libml 持久化, 与 VLC 同一存储
            "setProgress" -> worker.execute {
                val id = (call.argument<Number>("id") ?: -1).toLong()
                val timeMs = (call.argument<Number>("timeMs") ?: 0).toLong()
                val ok = try {
                    id >= 0 && (ml?.setLastTime(id, timeMs) ?: -1) == 0
                } catch (e: Throwable) {
                    Log.w(TAG, "setProgress: ${e.message}")
                    false
                }
                main.post { result.success(ok) }
            }

            "addHistory" -> worker.execute {
                val uri = call.argument<String>("uri") ?: ""
                val title = call.argument<String>("title") ?: ""
                val ok = try {
                    uri.isNotEmpty() && ml?.addToHistory(uri, title) == true
                } catch (e: Throwable) {
                    Log.w(TAG, "addHistory: ${e.message}")
                    false
                }
                main.post { result.success(ok) }
            }

            "rescan" -> worker.execute {
                try {
                    if (call.argument<Boolean>("full") == true) ml?.forceRescan() else ml?.reload()
                } catch (e: Throwable) {
                    Log.w(TAG, "rescan: ${e.message}")
                }
                main.post { result.success(null) }
            }

            "banFolder" -> worker.execute {
                val path = call.argument<String>("path") ?: ""
                try {
                    if (path.isNotEmpty()) ml?.banFolder(path)
                } catch (_: Throwable) {}
                main.post { result.success(null) }
            }

            else -> result.notImplemented()
        }
    }

    private fun describe(m: MediaWrapper): Map<String, Any> {
        var title = ""
        var uri = ""
        var lengthMs = 0L
        var timeMs = 0L
        var width = 0
        var height = 0
        var playCount = 0L
        var fileName = ""
        try {
            title = m.getTitle() ?: ""
            uri = m.getUri()?.toString() ?: m.getLocation() ?: ""
            lengthMs = m.getLength()
            timeMs = m.getTime()
            width = m.getWidth()
            height = m.getHeight()
            playCount = m.getPlayCount()
            fileName = m.getFileName() ?: ""
        } catch (e: Throwable) {
            Log.w(TAG, "describe: ${e.message}")
        }
        return mapOf(
            "id" to m.getId(),
            "title" to title,
            "uri" to uri,
            "lengthMs" to lengthMs,
            "timeMs" to timeMs,
            "width" to width,
            "height" to height,
            "playCount" to playCount,
            "fileName" to fileName,
        )
    }

    /**
     * 存储卷根目录列表: `/storage/emulated/0`、SD 卡 `/storage/XXXX-XXXX` 等。
     * 由应用私有目录反推卷根(与之前 Dart 侧 LocalMediaService.devicePaths
     * 相同的技巧), 不依赖任何存储权限即可枚举卷。
     */
    private fun storageRoots(): List<String> {
        val roots = LinkedHashSet<String>()
        try {
            for (dir in context.getExternalFilesDirs(null)) {
                if (dir == null) continue
                var f: File = dir
                // .../storage/<vol>/Android/data/<pkg>/files -> /storage/<vol>
                while (f.parentFile != null && f.name != "storage" && f.parentFile?.name != "storage") {
                    f = f.parentFile!!
                }
                if (f.parentFile?.name == "storage") {
                    roots.add(f.absolutePath)
                }
            }
        } catch (e: Throwable) {
            Log.w(TAG, "storageRoots: ${e.message}")
        }
        if (roots.isEmpty()) {
            roots.add("/storage/emulated/0")
        }
        return roots.toList()
    }

    private fun emit(name: String, args: Any?) {
        if (disposed) return
        main.post {
            try {
                channel.invokeMethod(name, args)
            } catch (_: Throwable) {}
        }
    }
}
