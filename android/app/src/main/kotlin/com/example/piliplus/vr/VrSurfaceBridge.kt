package com.example.piliplus.vr

import android.graphics.SurfaceTexture
import android.util.Log
import android.view.Surface

/**
 * 上游 xl_player 的 `SurfaceTextureBridge`
 * (xl-player-armv7a/src/main/java/com/xl/media/hwdecode/SurfaceTextureBridge.java) 的对等实现。
 *
 * **线程约定（与上游一致，不能改）**：`getSurface(texName)` 必须由持有 EGL 上下文的
 * **native GL 线程**经 JNI 调进来，这样 `SurfaceTexture(texName)` 就附着在那个上下文上；
 * 之后每帧的 `updateTexImage()` 同样由那个线程调用才合法。上游正是在
 * `xl_player_gl_thread.c` 的 `init_egl()` 里建、在 `draw_video_frame()` 里 updateTexImage。
 *
 * 与上游的两处差别，都是必要的：
 *  1. `setDefaultBufferSize()`：上游用 NDK MediaCodec（自己会设 buffer 几何），我们用 Java
 *     MediaCodec，显式设一次可以避免个别机型上 SurfaceTexture 停留在默认几何导致花屏。
 *  2. 帧到达回调：上游的 GL 循环从 FFmpeg 帧队列取帧，天然知道"有新帧"；我们的帧由
 *     MediaCodec 异步产出，所以挂一个 `OnFrameAvailableListener` 通知 native 标脏。
 *     必须显式传 Handler —— GL 线程是 native pthread，没有 Looper，不传就永远收不到回调。
 */
object VrSurfaceBridge {
    private var texture: SurfaceTexture? = null
    private var surface: Surface? = null
    private val matrix = FloatArray(16)
    private var pendingW = 0
    private var pendingH = 0
    private var onFrame: (() -> Unit)? = null

    @JvmStatic
    fun getSurface(name: Int): Surface? {
        releaseInternal()
        return try {
            val st = SurfaceTexture(name)
            if (pendingW > 0 && pendingH > 0) st.setDefaultBufferSize(pendingW, pendingH)
            val s = Surface(st)
            texture = st
            surface = s
            onFrame?.let { cb ->
                st.setOnFrameAvailableListener(
                    { cb() },
                    android.os.Handler(android.os.Looper.getMainLooper()),
                )
            }
            s
        } catch (e: Throwable) {
            Log.e("VrSurfaceBridge", "getSurface($name) 失败", e)
            null
        }
    }

    /** 由 Kotlin 侧在拿到视频宽高后调用；若 SurfaceTexture 已建好则立即生效。 */
    @JvmStatic
    fun setDefaultBufferSize(width: Int, height: Int) {
        pendingW = width
        pendingH = height
        try {
            texture?.setDefaultBufferSize(width, height)
        } catch (e: Throwable) {
            Log.w("VrSurfaceBridge", "setDefaultBufferSize: ${e.message}")
        }
    }

    @JvmStatic
    fun setOnFrameAvailable(callback: (() -> Unit)?) {
        onFrame = callback
    }

    @JvmStatic
    fun updateTexImage() {
        try {
            texture?.updateTexImage()
        } catch (e: Throwable) {
            Log.w("VrSurfaceBridge", "updateTexImage: ${e.message}")
        }
    }

    @JvmStatic
    fun getTransformMatrix(): FloatArray {
        try {
            texture?.getTransformMatrix(matrix)
        } catch (e: Throwable) {
            Log.w("VrSurfaceBridge", "getTransformMatrix: ${e.message}")
        }
        return matrix
    }

    @JvmStatic
    fun release() {
        releaseInternal()
    }

    private fun releaseInternal() {
        try {
            texture?.setOnFrameAvailableListener(null)
            texture?.release()
        } catch (_: Throwable) {
        }
        try {
            surface?.release()
        } catch (_: Throwable) {
        }
        texture = null
        surface = null
    }
}
