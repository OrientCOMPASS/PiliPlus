package com.example.piliplus.vlc

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.example.piliplus.LogCollector
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
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
 * 初始化序列严格对齐 vlc-android 的 MediaParsingService(§18.1 的教训——
 * 之前跳过 construct() 直接 init(), MedialibraryImpl 会抛
 * "Medialibrary construct has to be called before init", 真机上必失败):
 *
 *   Medialibrary.getInstance()      // 单例(MLServiceLocator 默认给真实现)
 *   → construct(context)            // 加载 libmla/libc++_shared、注册 JNI、定 db/缩略图路径
 *   → addDevice(uuid, path, removable) × 每个存储卷   // 必须在 init 前登记设备
 *   → init(context)                 // 打开/建库; 状态码 0/1/3/4 可用, 2/5 失败
 *   → setLibVLCInstance(ptr)        // libml 解析元数据/缩略图要用
 *   → start()                       // 起后台任务
 *   → banFolder(Android/) + discover(每个卷)
 *
 * 所有查询都在后台线程执行(libml 是 JNI 同步调用), 结果 post 回主线程。
 * 所有失败路径都写 [LogCollector](设置 → 日志 可查看/导出)。
 */
class VlcLibraryBridge(
    private val context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "piliplus/vlc_library"
        private const val TAG = "VlcLibraryBridge"
        private const val PRIMARY_ROOT = "/storage/emulated/0"
    }

    private val channel = MethodChannel(messenger, CHANNEL)
    private val main = Handler(Looper.getMainLooper())
    private val worker: ExecutorService = Executors.newSingleThreadExecutor()

    @Volatile
    private var ml: Medialibrary? = null

    /** construct() 每进程只许成功执行一次(nativeConstruct 会重复注册 JNI) */
    @Volatile
    private var constructed = false
    private var listenerAdded = false
    private var disposed = false

    private val readyListener = object : Medialibrary.OnMedialibraryReadyListener {
        override fun onMedialibraryReady() {
            LogCollector.i(TAG, "medialibrary ready")
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
            } catch (t: Throwable) {
                LogCollector.w(TAG, "dispose: ${t.message}")
            }
            ml = null
            listenerAdded = false
        }
        worker.shutdown()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "init" -> worker.execute {
                val reply = try {
                    doInit()
                } catch (t: Throwable) {
                    LogCollector.e(TAG, "init failed", t)
                    mapOf("error" to "${t.javaClass.simpleName}: ${t.message}")
                }
                main.post { result.success(reply) }
            }

            "videos" -> worker.execute {
                val list = try {
                    (ml?.getVideos() ?: emptyArray()).map { describe(it) }
                } catch (t: Throwable) {
                    LogCollector.w(TAG, "videos: ${t.message}")
                    emptyList()
                }
                main.post { result.success(list) }
            }

            "history" -> worker.execute {
                val list = try {
                    (ml?.history(Medialibrary.HISTORY_TYPE_LOCAL) ?: emptyArray()).map { describe(it) }
                } catch (t: Throwable) {
                    LogCollector.w(TAG, "history: ${t.message}")
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
                } catch (t: Throwable) {
                    LogCollector.w(TAG, "setProgress: ${t.message}")
                    false
                }
                main.post { result.success(ok) }
            }

            "addHistory" -> worker.execute {
                val uri = call.argument<String>("uri") ?: ""
                val title = call.argument<String>("title") ?: ""
                val ok = try {
                    uri.isNotEmpty() && ml?.addToHistory(uri, title) == true
                } catch (t: Throwable) {
                    LogCollector.w(TAG, "addHistory: ${t.message}")
                    false
                }
                main.post { result.success(ok) }
            }

            "rescan" -> worker.execute {
                try {
                    if (call.argument<Boolean>("full") == true) ml?.forceRescan() else ml?.reload()
                } catch (t: Throwable) {
                    LogCollector.w(TAG, "rescan: ${t.message}")
                }
                main.post { result.success(null) }
            }

            "banFolder" -> worker.execute {
                val path = call.argument<String>("path") ?: ""
                try {
                    if (path.isNotEmpty()) ml?.banFolder(path)
                } catch (t: Throwable) {
                    LogCollector.w(TAG, "banFolder: ${t.message}")
                }
                main.post { result.success(null) }
            }

            else -> result.notImplemented()
        }
    }

    // ------------------------------------------------------------------ init

    /** worker 线程调用; 返回给 Dart 的 map(status/roots 或 error)。 */
    private fun doInit(): Map<String, Any> {
        val inst = ml ?: Medialibrary.getInstance()

        if (!constructed) {
            LogCollector.i(TAG, "medialibrary construct()…")
            val ok = try {
                inst.construct(context)
            } catch (t: Throwable) {
                LogCollector.e(TAG, "construct threw", t)
                false
            }
            constructed = ok
            if (!ok) {
                LogCollector.e(
                    TAG,
                    "construct failed: libmla/libc++_shared 加载失败, 或存储目录不可用" +
                        "(externalFilesDir 不存在 / 私有 db 目录不可写)",
                )
                return mapOf(
                    "error" to "媒体库原生组件加载失败(construct), 详见 设置→关于→日志→引擎日志",
                )
            }
        }

        if (!inst.isInitiated) {
            val roots = storageRoots()
            // vlc-android 在 init 之前逐卷登记设备(主存储 uuid 固定 main-storage)
            for (root in roots) {
                val uuid = if (root == PRIMARY_ROOT) "main-storage" else root.substringAfterLast('/')
                try {
                    inst.addDevice(uuid, root, root != PRIMARY_ROOT)
                } catch (t: Throwable) {
                    LogCollector.w(TAG, "addDevice($root): ${t.message}")
                }
            }
            val status = try {
                inst.init(context)
            } catch (t: Throwable) {
                LogCollector.e(TAG, "init threw", t)
                return mapOf("error" to "媒体库初始化异常: ${t.javaClass.simpleName}: ${t.message}")
            }
            LogCollector.i(
                TAG,
                "medialibrary init status=$status " +
                    "(0=success 1=already 2=failed 3=db_reset 4=db_corrupted 5=unrecoverable)",
            )
            if (status == Medialibrary.ML_INIT_FAILED ||
                status == Medialibrary.ML_INIT_DB_UNRECOVERABLE
            ) {
                return mapOf("error" to "媒体库数据库初始化失败(status=$status), 详见 设置→关于→日志→引擎日志")
            }
            try {
                inst.setLibVLCInstance(VlcCore.get(context).instance)
            } catch (t: Throwable) {
                // 不影响扫描, 只影响 libml 的元数据解析/缩略图
                LogCollector.w(TAG, "setLibVLCInstance failed: ${t.message}")
            }
        }

        try {
            if (!inst.isStarted) {
                inst.start()
            }
            if (!listenerAdded) {
                inst.addOnMedialibraryReadyListener(readyListener)
                listenerAdded = true
            }
            for (root in storageRoots()) {
                try {
                    inst.banFolder(root + "/Android")
                } catch (_: Throwable) {
                }
                inst.discover(root)
            }
        } catch (t: Throwable) {
            LogCollector.e(TAG, "start/discover failed", t)
            return mapOf("error" to "媒体库启动扫描失败: ${t.javaClass.simpleName}: ${t.message}")
        }

        ml = inst
        LogCollector.i(TAG, "medialibrary init 完成, roots=${storageRoots()}")
        return mapOf("status" to 0, "roots" to storageRoots())
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
        } catch (t: Throwable) {
            LogCollector.w(TAG, "describe: ${t.message}")
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
        } catch (t: Throwable) {
            LogCollector.w(TAG, "storageRoots: ${t.message}")
        }
        if (roots.isEmpty()) {
            roots.add(PRIMARY_ROOT)
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
