package com.example.piliplus.localmedia

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import org.videolan.libvlc.Media
import org.videolan.libvlc.MediaPlayer
import org.videolan.libvlc.util.VLCVideoLayout

/**
 * Wraps one libvlc MediaPlayer for local / LAN playback.
 *
 * Emits a single map-based event stream (see LocalMediaPlugin.EVENT_CHANNEL):
 *  {type:"player", event:"opening|playing|paused|stopped|end|error|buffering|vout|esAdded", value?}
 *  {type:"time", ms:Long, lengthMs:Long}
 *  {type:"tracks", audio:[{id,name}], spu:[{id,name}], selAudio:Int, selSpu:Int}
 *  {type:"vrHud", yaw:Double, pitch:Double, fov:Double}
 *  {type:"focusLost"} / {type:"focusGained"}
 */
class PlayerBridge(private val context: Context) {

    companion object {
        private const val TAG = "PlayerBridge"
        private const val HUD_INTERVAL_MS = 100L
        private const val GYRO_MIN_INTERVAL_MS = 33L
    }

    private val main = Handler(Looper.getMainLooper())
    private var player: MediaPlayer? = null
    private var attachedView: VLCVideoLayout? = null

    private var uris: List<String> = emptyList()
    private var index: Int = 0
    private var pendingStartMs: Long = 0
    private var pendingRate: Float = 1f
    private var startedApplied = false

    @Volatile
    var lengthMs: Long = 0
        private set

    // ---- viewpoint state ---------------------------------------------------
    private var vpYaw = 0f
    private var vpPitch = 0f
    private var vpFov = 80f
    private var gyroEnabled = false
    private var gyroOffsetYaw = 0.0
    private var gyroOffsetPitch = 0.0
    private var lastGyroAt = 0L
    private var lastHudAt = 0L
    private var sensorManager: SensorManager? = null
    private var rotationSensor: Sensor? = null

    // ---- audio focus -------------------------------------------------------
    private var audioManager: AudioManager? = null
    private var focusRequest: AudioFocusRequest? = null
    private var resumeAfterFocus = false
    private val focusListener = AudioManager.OnAudioFocusChangeListener { change ->
        when (change) {
            AudioManager.AUDIOFOCUS_LOSS, AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> {
                if (isPlaying()) {
                    resumeAfterFocus = change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT
                    pause()
                    emit(mapOf("type" to "focusLost"))
                }
            }
            AudioManager.AUDIOFOCUS_GAIN -> {
                if (resumeAfterFocus) {
                    resumeAfterFocus = false
                    play()
                    emit(mapOf("type" to "focusGained"))
                }
            }
        }
    }

    var eventSink: ((Map<String, Any?>) -> Unit)? = null

    private fun emit(map: Map<String, Any?>) {
        main.post { eventSink?.invoke(map) }
    }

    private val listener = MediaPlayer.EventListener { event ->
        try {
            handleEvent(event)
        } catch (t: Throwable) {
            LogCollector.e(TAG, "event handling failed", t)
        }
    }

    private fun handleEvent(event: MediaPlayer.Event) {
        when (event.type) {
            MediaPlayer.Event.Opening -> emit(playerEvent("opening"))
            MediaPlayer.Event.Playing -> {
                emit(playerEvent("playing"))
                applyPendingStart()
            }
            MediaPlayer.Event.Paused -> emit(playerEvent("paused"))
            MediaPlayer.Event.Stopped -> emit(playerEvent("stopped"))
            MediaPlayer.Event.EndReached -> emit(playerEvent("end"))
            MediaPlayer.Event.EncounteredError -> {
                LogCollector.e(TAG, "libvlc reported EncounteredError for ${uris.getOrNull(index)}")
                emit(playerEvent("error"))
            }
            MediaPlayer.Event.Buffering ->
                emit(playerEvent("buffering", event.buffering.toDouble()))
            MediaPlayer.Event.LengthChanged -> {
                lengthMs = event.mediaPlayer.length
                emit(mapOf("type" to "time", "ms" to time(), "lengthMs" to lengthMs))
            }
            MediaPlayer.Event.TimeChanged ->
                emit(mapOf("type" to "time", "ms" to event.mediaPlayer.time, "lengthMs" to lengthMs))
            MediaPlayer.Event.Vout -> emit(playerEvent("vout", event.voutCount.toDouble()))
            MediaPlayer.Event.ESAdded, MediaPlayer.Event.ESDeleted -> publishTracks()
            MediaPlayer.Event.Seekable, MediaPlayer.Event.Pausable -> Unit
            else -> Unit
        }
    }

    private fun playerEvent(name: String, value: Double? = null): Map<String, Any?> =
        if (value != null) mapOf("type" to "player", "event" to name, "value" to value)
        else mapOf("type" to "player", "event" to name)

    private fun applyPendingStart() {
        if (startedApplied) return
        startedApplied = true
        val p = player ?: return
        if (pendingRate != 1f) runCatching { p.rate = pendingRate }
        if (pendingStartMs > 0) {
            runCatching { p.time = pendingStartMs }
            LogCollector.i(TAG, "resumed at ${pendingStartMs}ms")
        }
        publishTracks()
    }

    // ---- lifecycle ----------------------------------------------------------

    fun attach(layout: VLCVideoLayout) {
        val p = ensurePlayer()
        attachedView = layout
        runCatching {
            // subtitles=true: libvlc renders embedded/external SPU itself.
            p.attachViews(layout, null, true, false)
        }.onFailure { LogCollector.e(TAG, "attachViews failed", it) }
    }

    fun detach() {
        val p = player ?: return
        if (attachedView == null) return
        runCatching { p.detachViews() }
        attachedView = null
    }

    private fun ensurePlayer(): MediaPlayer {
        player?.let { return it }
        val instance = VlcEngine.ensureInit(context)
        val p = MediaPlayer(instance)
        p.setEventListener(listener)
        player = p
        return p
    }

    fun open(
        uris: List<String>, index: Int, startMs: Long, rate: Double,
        glVout: Boolean, networkCachingMs: Int
    ) {
        val p = ensurePlayer()
        this.uris = uris
        this.index = index
        pendingStartMs = startMs
        pendingRate = rate.toFloat()
        startedApplied = false
        lengthMs = 0
        playCurrent(p, glVout, networkCachingMs)
    }

    /** Re-open the same item (used for vout switches, keeps position). */
    fun reopen(glVout: Boolean, networkCachingMs: Int, keepPosition: Boolean) {
        val p = ensurePlayer()
        if (keepPosition) pendingStartMs = time()
        startedApplied = false
        playCurrent(p, glVout, networkCachingMs)
    }

    private fun playCurrent(p: MediaPlayer, glVout: Boolean, networkCachingMs: Int) {
        val uri = uris.getOrNull(index)
        if (uri == null) {
            emit(playerEvent("error"))
            return
        }
        val options = ArrayList<String>()
        if (glVout) options.add(":vout=gles2")
        if (networkCachingMs > 0 && !uri.startsWith("file:") && !uri.startsWith("content:") &&
            !uri.startsWith("/")
        ) {
            options.add(":network-caching=$networkCachingMs")
        }
        requestAudioFocus()
        try {
            val media = VlcEngine.buildMedia(context, uri, options)
            p.media = media
            media.release()
            p.play()
        } catch (t: Throwable) {
            LogCollector.e(TAG, "open failed: $uri", t)
            emit(playerEvent("error"))
        }
    }

    fun play() { player?.play() }
    fun pause() { player?.pause() }
    fun stop() {
        runCatching { player?.stop() }
        abandonAudioFocus()
    }

    fun isPlaying(): Boolean = try { player?.isPlaying == true } catch (t: Throwable) { false }

    fun time(): Long = try { player?.time ?: 0 } catch (t: Throwable) { 0 }

    fun seek(ms: Long, fast: Boolean) {
        val p = player ?: return
        runCatching {
            if (fast) p.setTime(ms, true) else p.time = ms
        }.onFailure {
            runCatching { p.time = ms }
        }
    }

    fun setRate(rate: Double) {
        runCatching { player?.rate = rate.toFloat() }
    }

    fun setNextIndex(i: Int) { index = i }
    fun currentIndex(): Int = index

    // ---- tracks -------------------------------------------------------------

    fun tracks(type: String): List<Map<String, Any?>> {
        val p = player ?: return emptyList()
        return try {
            val descs = if (type == "audio") p.audioTracks else p.spuTracks
            descs?.map { mapOf<String, Any?>("id" to it.id, "name" to (it.name ?: "")) } ?: emptyList()
        } catch (t: Throwable) {
            LogCollector.e(TAG, "tracks($type) failed", t)
            emptyList()
        }
    }

    fun selectedTrack(type: String): Int {
        val p = player ?: return -1
        return try {
            if (type == "audio") p.audioTrack else p.spuTrack
        } catch (t: Throwable) { -1 }
    }

    fun selectTrack(type: String, id: Int): Boolean {
        val p = player ?: return false
        return try {
            if (type == "audio") p.setAudioTrack(id) else p.setSpuTrack(id)
        } catch (t: Throwable) { false }
    }

    fun addSubtitle(uri: String): Boolean {
        val p = player ?: return false
        return try {
            p.addSlave(Media.Slave.Type.Subtitle, Uri.parse(uri), true)
        } catch (t: Throwable) {
            LogCollector.e(TAG, "addSlave subtitle failed: $uri", t)
            false
        }
    }

    fun publishTracks() {
        emit(
            mapOf(
                "type" to "tracks",
                "audio" to tracks("audio"),
                "spu" to tracks("spu"),
                "selAudio" to selectedTrack("audio"),
                "selSpu" to selectedTrack("spu")
            )
        )
    }

    // ---- VR -----------------------------------------------------------------

    fun vrVersion(): Int {
        val p = ensurePlayer()
        return VlcCompat.getVrVersion(p)
    }

    fun setVrMode(projection: Int, stereo: Int, eye: Int): Boolean {
        val p = player ?: return false
        val ok = VlcCompat.setVrMode(p, projection, stereo, eye)
        if (ok) LogCollector.i(TAG, "vr mode set: proj=$projection stereo=$stereo eye=$eye")
        return ok
    }

    fun updateViewpoint(yaw: Float, pitch: Float, fov: Float, absolute: Boolean): Boolean {
        val p = player ?: return false
        if (absolute) {
            vpYaw = yaw
            vpPitch = pitch
            vpFov = fov
        } else {
            vpYaw += yaw
            vpPitch += pitch
            vpFov += fov
        }
        return try {
            p.updateViewpoint(vpYaw, vpPitch, 0f, vpFov, true)
        } catch (t: Throwable) {
            LogCollector.e(TAG, "updateViewpoint failed", t)
            false
        }
    }

    fun resetViewpoint() {
        if (gyroEnabled) {
            // Re-center against the current sensor orientation.
            gyroOffsetYaw = -lastRawYaw
            gyroOffsetPitch = -lastRawPitch
        } else {
            updateViewpoint(0f, 0f, vpFov, true)
        }
        emitHud()
    }

    fun setFov(fov: Float) {
        vpFov = fov.coerceIn(20f, 150f)
        updateViewpoint(vpYaw, vpPitch, vpFov, true)
    }

    fun currentViewpoint(): Map<String, Any?> =
        mapOf("yaw" to vpYaw, "pitch" to vpPitch, "fov" to vpFov)

    private var lastRawYaw = 0.0
    private var lastRawPitch = 0.0

    private val sensorListener = object : SensorEventListener {
        private val rotationMatrix = FloatArray(9)
        private val orientation = FloatArray(3)

        override fun onSensorChanged(event: SensorEvent) {
            if (event.sensor.type != Sensor.TYPE_ROTATION_VECTOR) return
            val now = System.currentTimeMillis()
            SensorManager.getRotationMatrixFromVector(rotationMatrix, event.values)
            SensorManager.getOrientation(rotationMatrix, orientation)
            lastRawYaw = Math.toDegrees(orientation[0].toDouble())
            lastRawPitch = Math.toDegrees(orientation[1].toDouble())
            if (now - lastGyroAt < GYRO_MIN_INTERVAL_MS) return
            lastGyroAt = now
            val yaw = wrap180(-lastRawYaw + gyroOffsetYaw)
            val pitch = (-lastRawPitch + gyroOffsetPitch).coerceIn(-90.0, 90.0)
            val p = player ?: return
            runCatching {
                p.updateViewpoint(yaw.toFloat(), pitch.toFloat(), 0f, vpFov, true)
            }
            vpYaw = yaw.toFloat()
            vpPitch = pitch.toFloat()
            if (now - lastHudAt >= HUD_INTERVAL_MS) {
                lastHudAt = now
                emitHud()
            }
        }

        override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}
    }

    private fun emitHud() {
        emit(
            mapOf(
                "type" to "vrHud",
                "yaw" to vpYaw.toDouble(),
                "pitch" to vpPitch.toDouble(),
                "fov" to vpFov.toDouble()
            )
        )
    }

    fun setGyro(enabled: Boolean) {
        if (enabled == gyroEnabled) return
        gyroEnabled = enabled
        val sm = sensorManager
            ?: (context.getSystemService(Context.SENSOR_SERVICE) as? SensorManager)
                ?.also { sensorManager = it }
        if (enabled) {
            rotationSensor = rotationSensor ?: sm?.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR)
            val sensor = rotationSensor
            if (sensor == null) {
                LogCollector.w(TAG, "rotation vector sensor unavailable")
                gyroEnabled = false
                emit(mapOf("type" to "gyroUnavailable"))
                return
            }
            gyroOffsetYaw = -lastRawYaw
            gyroOffsetPitch = -lastRawPitch
            sm?.registerListener(sensorListener, sensor, SensorManager.SENSOR_DELAY_GAME)
        } else {
            sm?.unregisterListener(sensorListener)
        }
    }

    private fun wrap180(v: Double): Double {
        var r = v % 360.0
        if (r > 180.0) r -= 360.0
        if (r < -180.0) r += 360.0
        return r
    }

    // ---- misc ---------------------------------------------------------------

    fun setAspectRatio(aspect: String?) {
        runCatching { player?.setAspectRatio(aspect) }
    }

    fun setScale(scale: Float) {
        runCatching { player?.setScale(scale) }
    }

    /**
     * WYSIWYG snapshot via PixelCopy (the Java API exposes no libvlc
     * snapshot; PixelCopy also captures the current VR viewpoint correctly
     * and includes the subtitle surface).
     */
    fun takeSnapshot(path: String, callback: (Boolean) -> Unit) {
        val layout = attachedView
        if (layout == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.N) {
            callback(false)
            return
        }
        try {
            val surfaces = ArrayList<android.view.SurfaceView>()
            for (i in 0 until layout.childCount) {
                (layout.getChildAt(i) as? android.view.SurfaceView)?.let { surfaces.add(it) }
            }
            if (surfaces.isEmpty()) {
                callback(false)
                return
            }
            val video = surfaces[0]
            val w = video.width
            val h = video.height
            if (w <= 0 || h <= 0) {
                callback(false)
                return
            }
            val bitmap = android.graphics.Bitmap.createBitmap(w, h, android.graphics.Bitmap.Config.ARGB_8888)
            android.view.PixelCopy.request(video, bitmap, { result ->
                if (result != android.view.PixelCopy.SUCCESS) {
                    callback(false)
                    return@request
                }
                val afterSubs: () -> Unit = {
                    try {
                        java.io.FileOutputStream(path).use { out ->
                            bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, out)
                        }
                        callback(true)
                    } catch (t: Throwable) {
                        LogCollector.e(TAG, "snapshot write failed", t)
                        callback(false)
                    } finally {
                        bitmap.recycle()
                    }
                }
                val sub = surfaces.getOrNull(1)
                if (sub == null || sub.width <= 0 || sub.height <= 0) {
                    afterSubs()
                } else {
                    val subBmp = android.graphics.Bitmap.createBitmap(
                        sub.width, sub.height, android.graphics.Bitmap.Config.ARGB_8888
                    )
                    android.view.PixelCopy.request(sub, subBmp, { r2 ->
                        if (r2 == android.view.PixelCopy.SUCCESS) {
                            val canvas = android.graphics.Canvas(bitmap)
                            canvas.drawBitmap(subBmp, 0f, 0f, null)
                        }
                        subBmp.recycle()
                        afterSubs()
                    }, main)
                }
            }, main)
        } catch (t: Throwable) {
            LogCollector.e(TAG, "snapshot failed", t)
            callback(false)
        }
    }

    private fun requestAudioFocus() {
        val am = audioManager
            ?: (context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager)
                ?.also { audioManager = it }
            ?: return
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                if (focusRequest == null) {
                    focusRequest = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                        .setAudioAttributes(
                            AudioAttributes.Builder()
                                .setUsage(AudioAttributes.USAGE_MEDIA)
                                .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
                                .build()
                        )
                        .setOnAudioFocusChangeListener(focusListener, main)
                        .build()
                }
                focusRequest?.let { am.requestAudioFocus(it) }
            } else {
                @Suppress("DEPRECATION")
                am.requestAudioFocus(
                    focusListener, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN
                )
            }
        } catch (t: Throwable) {
            LogCollector.w(TAG, "audio focus request failed: $t")
        }
    }

    private fun abandonAudioFocus() {
        val am = audioManager ?: return
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                focusRequest?.let { am.abandonAudioFocusRequest(it) }
            } else {
                @Suppress("DEPRECATION")
                am.abandonAudioFocus(focusListener)
            }
        } catch (_: Throwable) {
        }
    }

    fun release() {
        setGyro(false)
        stop()
        runCatching { player?.detachViews() }
        runCatching { player?.release() }
        player = null
        attachedView = null
        uris = emptyList()
    }
}
