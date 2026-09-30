package com.example.piliplus.vr

import android.app.Activity
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry

/**
 * VR 播放器的 Flutter 桥（MethodChannel `piliplus/vr_player`）。
 *
 * 一次会话的组成：
 * ```
 * Dart: VrPlayerPage(Texture(textureId))  +  手势/按钮/设置
 *   │  MethodChannel
 *   ▼
 * VrPlayerBridge ── VrEngine(MediaCodec/AudioTrack, 主时钟)
 *                ├─ VrGlPipeline(EGL/GLES2, 视角是 uniform, 逐帧改)
 *                └─ VrHeadTracker(旋转矢量传感器, 无漂移)
 * ```
 *
 * 视角状态（yaw/pitch/fov）以 **native 为准**：Dart 只发增量指令
 * （`lookBy` / `setFov` / `resetView`），native 每帧把头追增量叠加上去，
 * 再按 10Hz 把读数回报给 Dart 显示。这样头追不经过 Flutter 往返，
 * 才能做到逐帧跟手（这正是 mpv 用户着色器方案做不到的）。
 */
class VrPlayerBridge(
    private val activity: Activity,
    private val textureRegistry: TextureRegistry,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    companion object {
        private const val TAG = "VrPlayerBridge"
        const val CHANNEL = "piliplus/vr_player"

        const val MIN_FOV = 25f
        const val MAX_FOV = 120f
        const val MAX_PITCH = 89f

        /** 读数回报间隔：够 UI 显示，又不会把 platform channel 打满 */
        private const val REPORT_INTERVAL_MS = 100L
    }

    private val channel = MethodChannel(messenger, CHANNEL)
    private val main = Handler(Looper.getMainLooper())

    private var gl: VrGlPipeline? = null
    private var engine: VrEngine? = null
    private var tracker: VrHeadTracker? = null
    private var textureEntry: TextureRegistry.SurfaceTextureEntry? = null

    private var stereo = false
    private var sideBySide = false
    private var leftEye = true
    private var gyroEnabled = false
    private var lastReportMs = 0L

    init {
        channel.setMethodCallHandler(this)
    }

    fun dispose() {
        releaseInternal()
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "create" -> result.success(create())
                "open" -> {
                    val uri = call.argument<String>("uri")
                    if (uri.isNullOrEmpty()) {
                        result.error("bad_args", "uri is required", null)
                        return
                    }
                    @Suppress("UNCHECKED_CAST")
                    val headers = call.argument<Map<String, String>>("headers")
                    val start = call.argument<Number>("startPositionUs")?.toLong() ?: 0L
                    applyProjection(call.argument<String>("projection") ?: "equirect360")
                    applyEye(call.argument<String>("eye") ?: "left")
                    setFov((call.argument<Number>("fov")?.toFloat()) ?: 90f)
                    open(uri, headers, start)
                    result.success(true)
                }
                "play" -> { engine?.play(); result.success(true) }
                "pause" -> { engine?.pause(); result.success(true) }
                "seekTo" -> {
                    engine?.seekTo(call.argument<Number>("us")?.toLong() ?: 0L)
                    result.success(true)
                }
                "setSpeed" -> {
                    engine?.setSpeed(call.argument<Number>("speed")?.toFloat() ?: 1f)
                    result.success(true)
                }
                "lookBy" -> {
                    lookBy(
                        call.argument<Number>("dyaw")?.toFloat() ?: 0f,
                        call.argument<Number>("dpitch")?.toFloat() ?: 0f,
                    )
                    result.success(true)
                }
                "setFov" -> { setFov(call.argument<Number>("fov")?.toFloat() ?: 90f); result.success(true) }
                "zoomBy" -> {
                    val g = gl
                    if (g != null) setFov(g.fovDeg / (call.argument<Number>("factor")?.toFloat() ?: 1f))
                    result.success(true)
                }
                "resetView" -> { resetView(); result.success(true) }
                "setProjection" -> { applyProjection(call.argument<String>("mode") ?: "equirect360"); result.success(true) }
                "setEye" -> { applyEye(call.argument<String>("eye") ?: "left"); result.success(true) }
                "setGyro" -> { setGyro(call.argument<Boolean>("enabled") ?: false); result.success(true) }
                // 渲染目标的缓冲区尺寸: Flutter 不会替插件设
                // SurfaceTexture 的 defaultBufferSize, 不设就是 0x0 -> 纯色画面
                "setRenderSize" -> {
                    gl?.setRenderSize(
                        call.argument<Number>("width")?.toInt() ?: 0,
                        call.argument<Number>("height")?.toInt() ?: 0,
                    )
                    result.success(true)
                }
                // 诊断: 跳过球面投影, 把解码帧原样贴出来
                "setPassthrough" -> {
                    gl?.passthrough = call.argument<Boolean>("enabled") ?: false
                    gl?.requestRender()
                    result.success(true)
                }
                "getDebugInfo" -> result.success(debugInfo())
                "getPosition" -> result.success(engine?.getPositionUs() ?: 0L)
                "getDuration" -> result.success(engine?.durationUs ?: 0L)
                "release" -> { releaseInternal(); result.success(true) }
                else -> result.notImplemented()
            }
        } catch (e: Throwable) {
            Log.e(TAG, "method ${call.method} failed", e)
            result.error("native_error", e.message, null)
        }
    }

    // ==================== 会话 ====================

    private fun create(): Long {
        releaseInternal()
        val entry = textureRegistry.createSurfaceTexture()
        textureEntry = entry
        val pipeline = VrGlPipeline(entry.surfaceTexture())
        gl = pipeline
        val tracker = VrHeadTracker(activity.applicationContext)
        this.tracker = tracker
        pipeline.onBeforeFrame = { onGlFrame() }
        pipeline.onError = { msg -> post("error", mapOf("message" to msg)) }
        pipeline.start()
        return entry.id()
    }

    private fun open(uri: String, headers: Map<String, String>?, startPositionUs: Long) {
        val pipeline = gl ?: run {
            post("error", mapOf("message" to "渲染管线未创建"))
            return
        }
        val e = VrEngine(activity.applicationContext, pipeline)
        engine = e
        e.onPrepared = { durationUs, hasAudio, w, h ->
            post(
                "prepared",
                mapOf(
                    "durationUs" to durationUs,
                    "hasAudio" to hasAudio,
                    "width" to w,
                    "height" to h,
                ),
            )
        }
        e.onEnded = { post("ended", emptyMap<String, Any>()) }
        e.onError = { msg -> post("error", mapOf("message" to msg)) }
        e.onBuffering = { buffering -> post("buffering", mapOf("value" to buffering)) }
        // 放到后台线程: VrEngine.open 里要等 GL 线程把 Surface 建好
        // (awaitVideoSurface 最多等 3s), 占着主线程会有 ANR 风险
        Thread({
            e.open(uri, headers, startPositionUs)
            e.play()
            main.post { resetView() }
        }, "pili-vr-open").start()
    }

    private fun releaseInternal() {
        val e = engine
        val g = gl
        val t = tracker
        val te = textureEntry
        engine = null
        gl = null
        tracker = null
        textureEntry = null
        t?.stop()
        // TextureRegistry 的 entry 必须在主线程释放
        if (te != null) {
            main.post {
                try {
                    te.release()
                } catch (ex: Throwable) {
                    Log.w(TAG, "texture release: ${ex.message}")
                }
            }
        }
        if (e == null && g == null) return
        // 解码线程要 join、GL 线程要 quit, 都可能耗上百毫秒 -> 后台做, 别卡主线程
        Thread({
            try {
                e?.release()
            } catch (ex: Throwable) {
                Log.w(TAG, "engine release: ${ex.message}")
            }
            // 先放引擎再停 GL: 引擎还持有 GL 给的 Surface
            try {
                g?.stop()
            } catch (ex: Throwable) {
                Log.w(TAG, "gl stop: ${ex.message}")
            }
        }, "pili-vr-release").start()
    }

    // ==================== 视角 ====================

    /** 每帧（vsync）：先叠头追增量，再按 10Hz 把读数回报给 Dart */
    private fun onGlFrame() {
        val g = gl ?: return
        if (gyroEnabled) {
            tracker?.let { t ->
                val (dyaw, dpitch) = t.drain()
                if (dyaw != 0f || dpitch != 0f) {
                    g.yawDeg = wrapOrClampYaw(g.yawDeg + dyaw, g.fovDeg)
                    g.pitchDeg = (g.pitchDeg + dpitch).coerceIn(-MAX_PITCH, MAX_PITCH)
                }
            }
        }
        val now = System.currentTimeMillis()
        if (now - lastReportMs < REPORT_INTERVAL_MS) return
        lastReportMs = now
        val e = engine
        val info = debugInfo()
        main.post {
            channel.invokeMethod(
                "view",
                mapOf(
                    "yaw" to g.yawDeg,
                    "pitch" to g.pitchDeg,
                    "fov" to g.fovDeg,
                    "positionUs" to (e?.getPositionUs() ?: 0L),
                    "debug" to info,
                ),
            )
        }
    }

    /** 一行诊断信息: 尺寸/帧数/GL 错误/解码状态, 真机排查"纯色画面"全靠它 */
    private fun debugInfo(): String {
        val g = gl
        val e = engine
        return (g?.debugInfo() ?: "gl=null") +
            " | decoded=${e?.decodedFrames ?: 0} rendered=${e?.renderedFrames ?: 0}" +
            " pos=${(e?.getPositionUs() ?: 0) / 1000}ms" +
            " playing=${e?.playing == true} dur=${(e?.durationUs ?: 0) / 1000000}s"
    }

    private fun lookBy(dyaw: Float, dpitch: Float) {
        val g = gl ?: return
        g.yawDeg = wrapOrClampYaw(g.yawDeg + dyaw, g.fovDeg)
        g.pitchDeg = (g.pitchDeg + dpitch).coerceIn(-MAX_PITCH, MAX_PITCH)
        g.requestRender()
    }

    private fun setFov(fov: Float) {
        val g = gl ?: return
        g.fovDeg = fov.coerceIn(MIN_FOV, MAX_FOV)
        // 180° 片源的偏航范围依赖 fov，改了 fov 要重新夹一次
        g.yawDeg = wrapOrClampYaw(g.yawDeg, g.fovDeg)
        g.requestRender()
    }

    private fun resetView() {
        val g = gl ?: return
        g.yawDeg = 0f
        g.pitchDeg = 0f
        tracker?.drain()
        g.requestRender()
    }

    /** 360° 片源回绕，180° 片源夹到 ±(coverage - fov)/2（转出画面会露黑边） */
    private fun wrapOrClampYaw(yaw: Float, fov: Float): Float {
        val g = gl ?: return yaw
        if (g.coverageHDeg >= 360f) {
            var v = yaw % 360f
            if (v > 180f) v -= 360f
            if (v < -180f) v += 360f
            return v
        }
        val limit = ((g.coverageHDeg - fov) / 2f).coerceAtLeast(0f)
        return yaw.coerceIn(-limit, limit)
    }

    private fun applyProjection(mode: String) {
        val g = gl ?: return
        when (mode) {
            "equirect180" -> { g.coverageHDeg = 180f; stereo = false }
            "sbs360" -> { g.coverageHDeg = 360f; stereo = true; sideBySide = true }
            "tb360" -> { g.coverageHDeg = 360f; stereo = true; sideBySide = false }
            "sbs180" -> { g.coverageHDeg = 180f; stereo = true; sideBySide = true }
            "tb180" -> { g.coverageHDeg = 180f; stereo = true; sideBySide = false }
            else -> { g.coverageHDeg = 360f; stereo = false }
        }
        applyEyeRect()
        g.yawDeg = wrapOrClampYaw(g.yawDeg, g.fovDeg)
        g.requestRender()
    }

    private fun applyEye(eye: String) {
        leftEye = eye != "right"
        applyEyeRect()
        gl?.requestRender()
    }

    private fun applyEyeRect() {
        val g = gl ?: return
        g.eyeRect = if (!stereo) {
            floatArrayOf(0f, 1f, 0f, 1f)
        } else if (sideBySide) {
            if (leftEye) floatArrayOf(0f, 0.5f, 0f, 1f) else floatArrayOf(0.5f, 1f, 0f, 1f)
        } else {
            if (leftEye) floatArrayOf(0f, 1f, 0f, 0.5f) else floatArrayOf(0f, 1f, 0.5f, 1f)
        }
    }

    private fun setGyro(enabled: Boolean) {
        gyroEnabled = enabled
        if (enabled) {
            tracker?.drain()
            tracker?.start()
        } else {
            tracker?.stop()
        }
    }

    private fun post(event: String, args: Map<String, Any>) {
        main.post {
            try {
                channel.invokeMethod(event, args)
            } catch (e: Throwable) {
                Log.w(TAG, "invokeMethod($event): ${e.message}")
            }
        }
    }
}
