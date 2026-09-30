package com.example.piliplus.vr

import android.graphics.SurfaceTexture
import android.util.Log
import android.view.Surface

/**
 * VR 渲染管线 —— **移植自 xl_player**（https://github.com/xl-player-developers/xl_player）。
 *
 * 历史：这个类原先是手写的 GLES2 渲染器（全屏四边形 + 逐像素等距柱状反投影）。真机测试
 * 暴露出三类问题：画面上下颠倒、陀螺仪俯仰反向、以及在 2560×1600 上卡顿。逐像素反投影的
 * 开销是根因（每像素 4 次三角函数 + normalize + atan + asin，Adreno 610 扛不住），改成球面
 * 网格后仍需要反复调符号/翻转。于是按需求改为直接移植上游久经考验的实现。
 *
 * 现在的分工：
 * ```
 * 上游 C 代码(android/app/src/main/cpp/xl/)  ← 网格/着色器/矩阵/模型/Cardboard EKF 头追, 原样搬
 *        ▲
 * cpp/xl_vr_jni.c                            ← EGL、渲染循环、JNI（替代上游绑死 FFmpeg 的
 *        ▲                                      xl_player_gl_thread.c）
 * 本类                                         ← 属性转发 + 生命周期
 *        ▲
 * VrEngine(MediaExtractor/MediaCodec/AudioTrack) ← 解码保留 Android 原生实现(见 cpp/CMakeLists.txt)
 * ```
 *
 * **视角语义变化**：yaw/pitch 现在只表示**手动**偏移；陀螺仪姿态由 native 的
 * `xl_tracker_get_last_view()`（OrientationEKF，含 33ms 前视补偿）每帧叠加，不再经过 Kotlin。
 * 属性 setter 会把"绝对值"换算成增量下发，所以调用方（VrPlayerBridge）无需改动。
 */
internal class VrGlPipeline(
    private val outputSurfaceTexture: SurfaceTexture,
) {

    companion object {
        private const val TAG = "VrGlPipeline"

        /** native 库加载失败时（例如非 arm ABI 的包）不要崩，退化成"VR 不可用"并给出原因。 */
        val nativeAvailable: Boolean
        val nativeLoadError: String?

        init {
            var err: String? = null
            var ok = false
            try {
                System.loadLibrary("xl_vr")
                ok = true
            } catch (e: Throwable) {
                err = e.message ?: e.javaClass.simpleName
                Log.e(TAG, "loadLibrary(xl_vr) 失败", e)
            }
            nativeAvailable = ok
            nativeLoadError = err
        }
    }

    // ==================== 对外属性（真值在 native，这里做转发） ====================

    /** 手动偏航（度）。写入时换算成增量下发，因为 native 侧是累加的。 */
    var yawDeg: Float = 0f
        set(value) {
            val delta = value - field
            field = value
            if (delta != 0f) nativeRotateBy(handle, delta, 0f)
            markDirty()
        }

    /** 手动俯仰（度），native 侧夹在 ±89°。 */
    var pitchDeg: Float = 0f
        set(value) {
            val delta = value - field
            field = value
            if (delta != 0f) nativeRotateBy(handle, 0f, delta)
            markDirty()
        }

    /** 水平视场角（度）。native 会按当前宽高比换算成上游 perspective() 需要的垂直 fov。 */
    var fovDeg: Float = 90f
        set(value) {
            field = value
            if (started) nativeSetFov(handle, value)
        }

    /** 水平覆盖角：360 或 180。 */
    var coverageHDeg: Float = 360f
        set(value) {
            field = value
            pushProjection()
        }

    /** 单眼在贴图上的区域 `[u0, u1, v0, v1]`；左右/上下布局就是把它取一半。 */
    var eyeRect: FloatArray = floatArrayOf(0f, 1f, 0f, 1f)
        set(value) {
            field = value
            pushProjection()
        }

    /**
     * 垂直翻转。上游直接把 `SurfaceTexture.getTransformMatrix()` 的结果喂给着色器，
     * 正常情况下**不需要**额外翻转，所以默认 false。真机若发现画面上下颠倒，
     * 打开诊断面板里的开关即可（会写进 native 的 texture_matrix，不动上游着色器）。
     */
    var flipV: Boolean = false
        set(value) {
            field = value
            if (started) nativeSetFlipV(handle, value)
        }

    /** 陀螺仪头追（native 的 Cardboard OrientationEKF）。 */
    var trackerEnabled: Boolean = false
        set(value) {
            field = value
            if (started) nativeSetTracker(handle, value)
        }

    /** 诊断用「原画直通」：换成上游的 Rect 模型（平面四边形），用来判断画面本身是否正常。 */
    var passthrough: Boolean = false
        set(value) {
            field = value
            if (started) nativeSetPassthrough(handle, value)
        }

    /** 手转轴符号，诊断用（真机上如果拖动方向反了，不用重新打包就能验证）。 */
    var axisSign: Pair<Float, Float> = Pair(1f, 1f)
        set(value) {
            field = value
            if (started) nativeSetAxisSign(handle, value.first, value.second)
        }

    var onError: ((String) -> Unit)? = null

    var ready: Boolean = false
        private set

    var videoSurface: Surface? = null
        private set

    var renderSize: String = "0x0"
        private set

    var videoSize: Pair<Int, Int> = Pair(0, 0)
        private set

    // ==================== 生命周期 ====================

    // start() 在后台线程跑，awaitVideoSurface()/setVideoSize() 可能来自别的线程 -> 要 volatile
    @Volatile
    private var handle: Long = 0L

    @Volatile
    private var started = false

    @Volatile
    private var destroyed = false
    private var outputSurface: Surface? = null

    private var pendingW = 0
    private var pendingH = 0

    fun setRenderSize(width: Int, height: Int) {
        if (width <= 0 || height <= 0) return
        renderSize = "${width}x$height"
        pendingW = width
        pendingH = height
        try {
            // Flutter 的 SurfaceTexture 不会自动跟随 widget 尺寸，必须显式设置，
            // 否则输出画面是默认几何（拉伸/模糊）。
            outputSurfaceTexture.setDefaultBufferSize(width, height)
        } catch (e: Throwable) {
            Log.w(TAG, "setDefaultBufferSize(output): ${e.message}")
        }
        if (started) nativeSetRenderSize(handle, width, height)
    }

    fun setVideoSize(width: Int, height: Int) {
        if (width <= 0 || height <= 0) return
        videoSize = Pair(width, height)
        // 视频侧的 SurfaceTexture 由 native 在 GL 线程创建，尺寸在这里补给它
        VrSurfaceBridge.setDefaultBufferSize(width, height)
        // start() 还没跑完时 handle 是 0，这里先记下，awaitVideoSurface() 拿到 Surface 后补推
        if (started && handle != 0L) nativeSetVideoSize(handle, width, height)
    }

    /**
     * 建 EGL / OES 纹理 / 视频 SurfaceTexture 并启动 native GL 线程。
     * **会阻塞**到 GL 线程就绪（最多 3s），所以必须在后台线程调用。
     */
    fun start() {
        if (started || destroyed) return
        if (!nativeAvailable) {
            reportError("native 库 xl_vr 加载失败: ${nativeLoadError ?: "unknown"}")
            return
        }
        val outSurface = Surface(outputSurfaceTexture)
        outputSurface = outSurface
        handle = nativeCreate(
            outSurface,
            coverageHDeg,
            eyeRect[0], eyeRect[1], eyeRect[2], eyeRect[3],
            fovDeg,
            trackerEnabled,
            flipV,
        )
        if (handle == 0L) {
            reportError("nativeCreate 失败（见 logcat VrXl）")
            return
        }
        // 帧到达回调：SurfaceTexture  latch 到新帧时通知 native 标脏
        VrSurfaceBridge.setOnFrameAvailable { nativeOnFrameAvailable(handle) }
        if (!nativeStart(handle)) {
            reportError("nativeStart 失败: " + nativeDebugInfo(handle))
            nativeDestroy(handle)
            handle = 0L
            return
        }
        nativeSetPassthrough(handle, passthrough)
        nativeSetTracker(handle, trackerEnabled)
        nativeSetFlipV(handle, flipV)
        started = true
        ready = true
        // Dart 的 setRenderSize 可能在 start() 之前就来了，这时补一次
        if (pendingW > 0 && pendingH > 0) nativeSetRenderSize(handle, pendingW, pendingH)
        videoSurface = nativeGetVideoSurface(handle)
        if (videoSurface == null) reportError("拿不到视频 Surface（VrSurfaceBridge.getSurface 失败）")
        Log.i(TAG, "xl_player 渲染器已启动 ${nativeDebugInfo(handle)}")
    }

    /**
     * 等 native GL 线程把视频 Surface 建好（[start] 已经阻塞等过，这里只是再取一次并兜底）。
     * 由 VrEngine 在后台线程调用，用来 configure MediaCodec。
     */
    fun awaitVideoSurface(timeoutMs: Long = 3000): Surface? {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (videoSurface == null && System.currentTimeMillis() < deadline && !destroyed) {
            if (handle != 0L) {
                videoSurface = nativeGetVideoSurface(handle)
                if (videoSurface != null) break
            }
            try {
                Thread.sleep(20)
            } catch (_: InterruptedException) {
                break
            }
        }
        // VrEngine 的顺序是 setVideoSize() -> awaitVideoSurface()，那时 start() 可能还没跑完，
        // nativeSetVideoSize 被跳过了 —— 这里补一次，否则模型会按默认宽高算 width_adjustment。
        val (vw, vh) = videoSize
        if (videoSurface != null && vw > 0 && vh > 0 && handle != 0L) {
            nativeSetVideoSize(handle, vw, vh)
        }
        return videoSurface
    }

    /** 有新帧可取（VrEngine 每次 releaseOutputBuffer(render=true) 后调用）。 */
    fun requestRender() {
        if (started) nativeOnFrameAvailable(handle)
    }

    /** 视角/参数变了但画面没新帧时，强制重画一次。 */
    fun markDirty() {
        if (started) nativeMarkDirty(handle)
    }

    /** 把当前设备朝向设为正前方（陀螺仪开启时由 native 记录参考姿态）。 */
    fun resetView() {
        if (started) nativeResetView(handle)
        markDirty()
    }

    fun debugInfo(): String {
        if (handle == 0L) return "native=未启动${nativeLoadError?.let { " err=$it" } ?: ""}"
        return try {
            nativeDebugInfo(handle)
        } catch (e: Throwable) {
            "native=异常 ${e.message}"
        }
    }

    fun stop() {
        if (destroyed) return
        destroyed = true
        ready = false
        VrSurfaceBridge.setOnFrameAvailable(null)
        if (handle != 0L) {
            try {
                nativeStop(handle)
                nativeDestroy(handle)
            } catch (e: Throwable) {
                Log.w(TAG, "native release: ${e.message}")
            }
            handle = 0L
        }
        started = false
        videoSurface = null
        try {
            outputSurface?.release()
        } catch (_: Throwable) {
        }
        outputSurface = null
    }

    // ==================== 内部 ====================

    private fun pushProjection() {
        if (!started) return
        nativeSetProjection(handle, coverageHDeg, eyeRect[0], eyeRect[1], eyeRect[2], eyeRect[3])
    }

    private fun reportError(msg: String) {
        Log.e(TAG, msg)
        onError?.invoke(msg)
    }

    // ==================== JNI（实现见 cpp/xl_vr_jni.c） ====================

    private external fun nativeCreate(
        outSurface: Surface,
        coverage: Float,
        u0: Float,
        u1: Float,
        v0: Float,
        v1: Float,
        fovh: Float,
        tracker: Boolean,
        flipV: Boolean,
    ): Long

    private external fun nativeStart(handle: Long): Boolean
    private external fun nativeGetVideoSurface(handle: Long): Surface?
    private external fun nativeSetRenderSize(handle: Long, width: Int, height: Int)
    private external fun nativeSetVideoSize(handle: Long, width: Int, height: Int)
    private external fun nativeSetProjection(
        handle: Long,
        coverage: Float,
        u0: Float,
        u1: Float,
        v0: Float,
        v1: Float,
    )

    private external fun nativeSetFov(handle: Long, fovh: Float)
    private external fun nativeRotateBy(handle: Long, yawDeg: Float, pitchDeg: Float)
    private external fun nativeResetView(handle: Long)
    private external fun nativeSetTracker(handle: Long, on: Boolean)
    private external fun nativeSetFlipV(handle: Long, flip: Boolean)
    private external fun nativeSetAxisSign(handle: Long, yawSign: Float, pitchSign: Float)
    private external fun nativeSetPassthrough(handle: Long, on: Boolean)
    private external fun nativeOnFrameAvailable(handle: Long)
    private external fun nativeMarkDirty(handle: Long)
    private external fun nativeDebugInfo(handle: Long): String
    private external fun nativeStop(handle: Long)
    private external fun nativeDestroy(handle: Long)
}
