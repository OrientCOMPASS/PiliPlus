package com.example.piliplus.vlc

import android.content.Context
import android.graphics.SurfaceTexture
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import org.videolan.libvlc.Media
import org.videolan.libvlc.MediaPlayer
import org.videolan.libvlc.interfaces.IMedia
import org.videolan.libvlc.interfaces.IVLCVout
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * VLC 播放器的 Flutter 桥(MethodChannel `piliplus/vlc_player`)。
 *
 * 渲染路径与 media_kit/mpv 相同的"外部纹理"模式:
 *
 *   libvlc ──(硬解 MediaCodec)──> vout ──> SurfaceTexture(Flutter TextureRegistry)
 *                                              │ Flutter Texture widget 合成
 *                                              ▼
 *                                   Flutter 控件叠在同一帧上
 *
 * 线程约定(沿用上一代 native 播放器的教训, 见 docs/piliplayer.md §10.5):
 *  - SurfaceTextureEntry 的创建/释放必须在主线程;
 *  - Media.parse / player.stop / release 可能阻塞(网络源), 一律丢到 [worker];
 *  - libvlc 事件对象是**复用**的, 必须在回调线程里同步取出数值再 post 到主线程;
 *  - 360° 头追用系统 ROTATION_VECTOR(绝对姿态, 相邻两帧取差), 与手动视角
 *    叠加后统一走 `updateViewpoint(..., absolute=true)`。
 */
class VlcPlayerBridge(
    private val context: Context,
    messenger: BinaryMessenger,
    private val textureRegistry: TextureRegistry,
) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "piliplus/vlc_player"
        private const val TAG = "VlcPlayerBridge"
        private const val POSITION_THROTTLE_MS = 200L
    }

    private val channel = MethodChannel(messenger, CHANNEL)
    private val main = Handler(Looper.getMainLooper())
    private val worker: ExecutorService = Executors.newSingleThreadExecutor()

    private var player: MediaPlayer? = null
    private var media: Media? = null
    private var textureEntry: TextureRegistry.SurfaceTextureEntry? = null
    private var disposed = false

    // ---- 360° 视角状态(度) ----
    private var vpYaw = 0f
    private var vpPitch = 0f
    private var vpFov = 80f
    private var is360 = false
    private var gyroOn = false
    private var headBaseSet = false
    private var headBaseYaw = 0f
    private var headBasePitch = 0f
    private var headYaw = 0f
    private var headPitch = 0f
    private val rotMat = FloatArray(9)
    private val orient = FloatArray(3)

    private var pendingRate = 1.0f
    private var lastPosEventMs = 0L
    private var videoW = 0
    private var videoH = 0
    private var sarNum = 1
    private var sarDen = 1

    private val sensorManager: SensorManager by lazy {
        context.getSystemService(Context.SENSOR_SERVICE) as SensorManager
    }
    private var rotationSensor: Sensor? = null

    private val sensorListener = object : SensorEventListener {
        override fun onSensorChanged(event: SensorEvent) {
            SensorManager.getRotationMatrixFromVector(rotMat, event.values)
            SensorManager.getOrientation(rotMat, orient)
            val yaw = Math.toDegrees(orient[0].toDouble()).toFloat()
            val pitch = Math.toDegrees(orient[1].toDouble()).toFloat()
            if (!headBaseSet) {
                headBaseYaw = yaw
                headBasePitch = pitch
                headBaseSet = true
                return
            }
            var dy = yaw - headBaseYaw
            // 方位角回绕到 [-180, 180]
            while (dy > 180f) dy -= 360f
            while (dy < -180f) dy += 360f
            headYaw = dy
            headPitch = pitch - headBasePitch
            applyViewpoint()
        }

        override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit
    }

    private val layoutListener = IVLCVout.OnNewVideoLayoutListener { _, width, height, visibleWidth, visibleHeight, sarN, sarD ->
        // 教训(§11.1): Flutter 不会替你设 SurfaceTexture 缓冲尺寸, 不设就是纯色画面
        val w = if (visibleWidth > 0) visibleWidth else width
        val h = if (visibleHeight > 0) visibleHeight else height
        if (w > 0 && h > 0) {
            try {
                textureEntry?.surfaceTexture()?.setDefaultBufferSize(w, h)
            } catch (e: Throwable) {
                Log.w(TAG, "setDefaultBufferSize: ${e.message}")
            }
            videoW = w
            videoH = h
            sarNum = if (sarN > 0) sarN else 1
            sarDen = if (sarD > 0) sarD else 1
            emit(
                "onVideoLayout",
                mapOf(
                    "width" to width, "height" to height,
                    "visibleWidth" to w, "visibleHeight" to h,
                    "sarNum" to sarNum, "sarDen" to sarDen,
                ),
            )
        }
    }

    private val eventListener = MediaPlayer.EventListener { event ->
        // event 对象会被 libvlc 复用: 数值必须在这里同步取出
        when (event.type) {
            MediaPlayer.Event.TimeChanged -> {
                val t = event.getTimeChanged()
                val now = System.currentTimeMillis()
                if (now - lastPosEventMs >= POSITION_THROTTLE_MS) {
                    lastPosEventMs = now
                    val len = try { player?.getLength() ?: 0L } catch (_: Throwable) { 0L }
                    emit("onPosition", mapOf("timeMs" to t, "lengthMs" to len))
                }
            }
            MediaPlayer.Event.LengthChanged -> {
                val len = event.getLengthChanged()
                emit("onPrepared", mapOf("lengthMs" to len, "is360" to is360))
            }
            MediaPlayer.Event.Playing -> {
                if (pendingRate != 1.0f) {
                    try { player?.setRate(pendingRate) } catch (_: Throwable) {}
                }
                emit("onPlaying", null)
                pushTracks()
            }
            MediaPlayer.Event.Paused -> emit("onPaused", null)
            MediaPlayer.Event.Stopped -> emit("onStopped", null)
            MediaPlayer.Event.EndReached -> emit("onEnded", null)
            MediaPlayer.Event.EncounteredError -> emit("onError", mapOf("message" to "VLC 播放失败"))
            MediaPlayer.Event.Buffering -> emit("onBuffering", mapOf("percent" to event.getBuffering()))
            MediaPlayer.Event.Vout -> emit("onVout", mapOf("count" to event.getVoutCount()))
            MediaPlayer.Event.ESAdded, MediaPlayer.Event.ESDeleted, MediaPlayer.Event.ESSelected ->
                pushTracks()
        }
    }

    init {
        channel.setMethodCallHandler(this)
    }

    fun dispose() {
        if (disposed) return
        disposed = true
        channel.setMethodCallHandler(null)
        setGyro(false)
        worker.execute { releasePlayer() }
        worker.shutdown()
        main.post { releaseTexture() }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "open" -> open(call, result)
            "play" -> { worker.execute { try { player?.play() } catch (_: Throwable) {} }; result.success(null) }
            "pause" -> { worker.execute { try { player?.pause() } catch (_: Throwable) {} }; result.success(null) }
            "stop" -> { worker.execute { try { player?.stop() } catch (_: Throwable) {} }; result.success(null) }
            "seekTo" -> {
                val ms = (call.argument<Number>("ms") ?: 0).toLong()
                worker.execute { try { player?.setTime(ms) } catch (_: Throwable) {} }
                result.success(null)
            }
            "setRate" -> {
                val rate = (call.argument<Number>("rate") ?: 1.0).toFloat()
                pendingRate = rate
                worker.execute { try { player?.setRate(rate) } catch (_: Throwable) {} }
                result.success(null)
            }
            "getTracks" -> result.success(tracksMap())
            "setAudioTrack" -> {
                val id = (call.argument<Number>("id") ?: -1).toInt()
                worker.execute { try { player?.setAudioTrack(id) } catch (_: Throwable) {} }
                result.success(null)
            }
            "setSpuTrack" -> {
                val id = (call.argument<Number>("id") ?: -1).toInt()
                worker.execute { try { player?.setSpuTrack(id) } catch (_: Throwable) {} }
                result.success(null)
            }
            "addSubtitle" -> {
                val path = call.argument<String>("path") ?: ""
                worker.execute {
                    try {
                        player?.addSlave(IMedia.Slave.Type.Subtitle, Uri.parse(path), true)
                    } catch (e: Throwable) {
                        Log.w(TAG, "addSubtitle: ${e.message}")
                    }
                }
                result.success(null)
            }
            "setScale" -> {
                val mode = call.argument<String>("mode") ?: "bestFit"
                val scale = when (mode) {
                    "fill" -> MediaPlayer.ScaleType.SURFACE_FILL
                    "fitScreen" -> MediaPlayer.ScaleType.SURFACE_FIT_SCREEN
                    else -> MediaPlayer.ScaleType.SURFACE_BEST_FIT
                }
                worker.execute { try { player?.setVideoScale(scale) } catch (_: Throwable) {} }
                result.success(null)
            }
            "setAspect" -> {
                val aspect = call.argument<String>("aspect") // "" = 自动
                worker.execute {
                    try { player?.setAspectRatio(aspect?.takeIf { it.isNotEmpty() }) } catch (_: Throwable) {}
                }
                result.success(null)
            }
            "lookBy" -> {
                val dyaw = (call.argument<Number>("dyaw") ?: 0).toFloat()
                val dpitch = (call.argument<Number>("dpitch") ?: 0).toFloat()
                vpYaw = wrap180(vpYaw + dyaw)
                vpPitch = (vpPitch + dpitch).coerceIn(-89f, 89f)
                applyViewpoint()
                result.success(mapOf("yaw" to vpYaw, "pitch" to vpPitch, "fov" to vpFov))
            }
            "setFov" -> {
                vpFov = ((call.argument<Number>("fov") ?: 80).toFloat()).coerceIn(20f, 140f)
                applyViewpoint()
                result.success(mapOf("fov" to vpFov))
            }
            "resetView" -> {
                vpYaw = 0f
                vpPitch = 0f
                headBaseSet = false
                headYaw = 0f
                headPitch = 0f
                applyViewpoint()
                result.success(null)
            }
            "setGyro" -> {
                setGyro(call.argument<Boolean>("on") ?: false)
                result.success(null)
            }
            "getState" -> {
                val p = player
                result.success(
                    if (p == null) null
                    else mapOf(
                        "timeMs" to (try { p.getTime() } catch (_: Throwable) { 0L }),
                        "lengthMs" to (try { p.getLength() } catch (_: Throwable) { 0L }),
                        "isPlaying" to (try { p.isPlaying() } catch (_: Throwable) { false }),
                        "seekable" to (try { p.isSeekable() } catch (_: Throwable) { false }),
                        "is360" to is360,
                    ),
                )
            }
            "release" -> {
                setGyro(false)
                worker.execute { releasePlayer() }
                main.post { releaseTexture() }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    // ------------------------------------------------------------------ open

    private fun open(call: MethodCall, result: MethodChannel.Result) {
        val uriStr = call.argument<String>("uri")
        if (uriStr.isNullOrEmpty()) {
            result.error("bad_args", "uri is required", null)
            return
        }
        val startMs = (call.argument<Number>("startMs") ?: 0).toLong()
        pendingRate = (call.argument<Number>("rate") ?: 1.0).toFloat()
        vpYaw = 0f; vpPitch = 0f; vpFov = 80f
        headBaseSet = false; headYaw = 0f; headPitch = 0f
        is360 = false
        videoW = 0; videoH = 0

        // 纹理与 vout 附着都在主线程做(上一代的 ANR/黑屏教训)
        val entry = try {
            textureRegistry.createSurfaceTexture()
        } catch (e: Throwable) {
            result.error("texture", "createSurfaceTexture failed: ${e.message}", null)
            return
        }
        val oldEntry = textureEntry
        textureEntry = entry
        oldEntry?.let { main.post { try { it.release() } catch (_: Throwable) {} } }

        val p = try {
            MediaPlayer(VlcCore.get(context))
        } catch (e: Throwable) {
            main.post { try { entry.release() } catch (_: Throwable) {} }
            result.error("vlc_init", "LibVLC init failed: ${e.message}", null)
            return
        }
        player?.let { old -> worker.execute { try { old.stop(); old.release() } catch (_: Throwable) {} } }
        player = p
        p.setEventListener(eventListener)
        try {
            val vout = p.getVLCVout()
            vout.setVideoSurface(entry.surfaceTexture())
            vout.attachViews(layoutListener)
        } catch (e: Throwable) {
            Log.e(TAG, "attach surface failed", e)
        }
        result.success(entry.id())

        worker.execute {
            var m: Media? = null
            try {
                m = Media(VlcCore.get(context), Uri.parse(uriStr))
                if (startMs > 0) {
                    m.addOption(":start-time=" + (startMs / 1000.0))
                }
                // 同步解析: 360° 检测需要轨道的 projection 元数据。
                // 网络源可能耗时数秒, 所以在后台线程做, 失败不阻断播放。
                try {
                    m.parse(IMedia.Parse.ParseLocal or IMedia.Parse.ParseNetwork or IMedia.Parse.FetchLocal)
                    for (i in 0 until m.trackCount) {
                        val t = m.getTrack(i)
                        if (t != null && t.type == IMedia.Track.Type.Video && t is IMedia.VideoTrack) {
                            if (t.projection != 0) is360 = true
                            if (videoW == 0 && t.width > 0) {
                                videoW = t.width; videoH = t.height
                                sarNum = if (t.sarNum > 0) t.sarNum else 1
                                sarDen = if (t.sarDen > 0) t.sarDen else 1
                            }
                        }
                    }
                } catch (e: Throwable) {
                    Log.w(TAG, "media parse: ${e.message}")
                }
                media?.let { old -> try { old.release() } catch (_: Throwable) {} }
                media = m
                p.setMedia(m)
                p.play()
            } catch (e: Throwable) {
                Log.e(TAG, "open failed", e)
                emit("onError", mapOf("message" to "打开失败: ${e.message}"))
            }
        }
    }

    // -------------------------------------------------------------- internals

    private fun applyViewpoint() {
        val p = player ?: return
        if (!is360) return
        try {
            p.updateViewpoint(vpYaw + headYaw, vpPitch + headPitch, 0f, vpFov, true)
        } catch (e: Throwable) {
            Log.w(TAG, "updateViewpoint: ${e.message}")
        }
    }

    private fun setGyro(on: Boolean) {
        if (gyroOn == on) return
        gyroOn = on
        if (on) {
            if (rotationSensor == null) {
                rotationSensor = sensorManager.getDefaultSensor(Sensor.TYPE_GAME_ROTATION_VECTOR)
                    ?: sensorManager.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR)
            }
            val s = rotationSensor
            if (s == null) {
                emit("onGyroUnavailable", null)
                gyroOn = false
                return
            }
            headBaseSet = false
            sensorManager.registerListener(sensorListener, s, SensorManager.SENSOR_DELAY_GAME)
        } else {
            try { sensorManager.unregisterListener(sensorListener) } catch (_: Throwable) {}
            headYaw = 0f
            headPitch = 0f
        }
    }

    private fun tracksMap(): Map<String, Any>? {
        val p = player ?: return null
        fun desc(list: Array<MediaPlayer.TrackDescription>?) =
            (list ?: emptyArray()).map { mapOf("id" to it.id, "name" to (it.name ?: "")) }
        return try {
            mapOf(
                "audio" to desc(p.getAudioTracks()),
                "spu" to desc(p.getSpuTracks()),
                "video" to desc(p.getVideoTracks()),
                "curAudio" to p.getAudioTrack(),
                "curSpu" to p.getSpuTrack(),
                "curVideo" to p.getVideoTrack(),
            )
        } catch (e: Throwable) {
            Log.w(TAG, "tracksMap: ${e.message}")
            null
        }
    }

    private fun pushTracks() {
        val m = tracksMap() ?: return
        emit("onTracks", m)
    }

    private fun releasePlayer() {
        val p = player
        val m = media
        player = null
        media = null
        if (p != null) {
            try {
                p.setEventListener(null)
                p.stop()
            } catch (_: Throwable) {}
            main.post {
                try { p.getVLCVout().detachViews() } catch (_: Throwable) {}
                try { p.release() } catch (_: Throwable) {}
            }
        }
        if (m != null) {
            try { m.release() } catch (_: Throwable) {}
        }
    }

    private fun releaseTexture() {
        textureEntry?.let { try { it.release() } catch (_: Throwable) {} }
        textureEntry = null
    }

    private fun emit(name: String, args: Any?) {
        if (disposed) return
        main.post {
            try {
                channel.invokeMethod(name, args)
            } catch (_: Throwable) {
                // Flutter 侧已断开, 忽略
            }
        }
    }

    private fun wrap180(v: Float): Float {
        var r = v % 360f
        if (r > 180f) r -= 360f
        if (r < -180f) r += 360f
        return r
    }

}
