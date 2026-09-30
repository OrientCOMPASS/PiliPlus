package com.example.piliplus.vr

import android.graphics.SurfaceTexture
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLSurface
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.opengl.Matrix
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.Choreographer
import android.view.Surface
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import kotlin.math.atan
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.tan

/**
 * 自研 VR 渲染管线：EGL + GLES2 + SurfaceTexture。
 *
 * 为什么要有它（对应真机反馈「VR 模式应该切到 xl_player 那样的播放器而不是 mpv」）：
 * mpv 的 `vo=gpu` 用户着色器**不支持 `//!PARAM`**，视角参数只能烘焙进源码，
 * 于是「改视角 = 换源码 = 重建整条渲染管线 + 重新编译一份 GLSL」，
 * 逐帧头追在那条路上做不到（详见 docs/piliplayer.md 9.1）。
 *
 * 管线（与 xl_player 同构）：
 * ```
 * MediaCodec 硬解 -> SurfaceTexture(OES 纹理) -> 自己的 GLES2 程序
 *                                             -> Flutter TextureRegistry
 * ```
 * 视角是**每帧 uniform**（MVP 矩阵），不重编译、不重建管线。
 *
 * ## 投影放在顶点着色器里（第七轮的关键修正）
 *
 * 第六轮用的是「全屏四边形 + 片元着色器逐像素做等距柱状→直线投影」，
 * 每个像素都要算 4 次三角函数 + `normalize` + `atan` + `asin`。
 * 在 2560x1600 的平板上按 vsync 连出 60 帧，就是每秒两亿多次超越函数运算 ——
 * Adreno 610 根本吃不消，表现就是卡顿、解码线程抢不到 CPU、频繁"缓冲中"。
 *
 * 现在改成 **UV 球面网格**（xl_player / ExoPlayer `SphericalGLSurfaceView` 的做法）：
 * 经纬度→xyz 的三角函数在**生成网格时算一次**（约 2000 个顶点），
 * 每帧只在 CPU 上算一个 MVP 矩阵当 uniform；片元着色器退化成
 * **一次纹理采样**。GPU 负载下降三个数量级，这才是能逐帧头追的前提。
 *
 * 线程模型：一个 [HandlerThread] 上跑 EGL 上下文，用 [Choreographer] 跟 vsync；
 * 并且只在"有新帧或视角变了"时才真正 draw（[dirty]），静止画面不做无谓渲染。
 */
internal class VrGlPipeline(
    /** Flutter 侧 `TextureRegistry.createSurfaceTexture()` 给的输出目标 */
    private val outputSurfaceTexture: SurfaceTexture,
) {
    companion object {
        private const val TAG = "VrGlPipeline"

        /** 球面网格密度：经度分段 / 纬度分段（360° 片源） */
        private const val LON_SEGS_360 = 72
        private const val LAT_SEGS = 36

        private const val FLOAT_BYTES = 4
        private const val STRIDE = 5 * FLOAT_BYTES // x, y, z, u, v

        // ---------- 球面网格：顶点着色器算 MVP，片元只采样 ----------
        private const val SPHERE_VS = """
            attribute vec4 aPos;
            attribute vec2 aUv;
            uniform mat4 uMvp;
            uniform mat4 uTexMatrix;
            uniform float uFlipV;
            uniform vec4 uEye;
            varying vec2 vUv;
            void main() {
              gl_Position = uMvp * aPos;
              // 双目片源只取一只眼睛; v 方向是否翻转见 uFlipV 的注释
              vec2 uv = vec2(mix(uEye.x, uEye.y, aUv.x), mix(uEye.z, uEye.w, aUv.y));
              uv.y = mix(uv.y, 1.0 - uv.y, uFlipV);
              // SurfaceTexture 的变换矩阵是仿射的, 放在顶点着色器里算完全等价,
              // 但只在 ~2000 个顶点上跑, 而不是几百万个像素
              vUv = (uTexMatrix * vec4(uv, 0.0, 1.0)).xy;
            }
        """

        private const val SPHERE_FS = """
            #extension GL_OES_EGL_image_external : require
            precision mediump float;
            varying vec2 vUv;
            uniform samplerExternalOES uVideo;
            void main() {
              gl_FragColor = texture2D(uVideo, vUv);
            }
        """

        // ---------- 诊断用的"原画直通"：全屏四边形，不投影 ----------
        private const val FLAT_VS = """
            attribute vec2 aPos;
            varying vec2 vUv;
            void main() {
              vUv = vec2(aPos.x * 0.5 + 0.5, 0.5 - aPos.y * 0.5);
              gl_Position = vec4(aPos, 0.0, 1.0);
            }
        """

        private const val FLAT_FS = """
            #extension GL_OES_EGL_image_external : require
            precision mediump float;
            varying vec2 vUv;
            uniform samplerExternalOES uVideo;
            uniform mat4 uTexMatrix;
            uniform float uFlipV;
            void main() {
              vec2 uv = vec2(vUv.x, mix(vUv.y, 1.0 - vUv.y, uFlipV));
              gl_FragColor = texture2D(uVideo, (uTexMatrix * vec4(uv, 0.0, 1.0)).xy);
            }
        """
    }

    // ==================== 视角状态（渲染线程读，其它线程写） ====================

    @Volatile
    var yawDeg: Float = 0f

    @Volatile
    var pitchDeg: Float = 0f

    @Volatile
    var fovDeg: Float = 90f

    /** 水平覆盖角：360 片源可以无限转，180 片源要在边界收敛 */
    @Volatile
    var coverageHDeg: Float = 360f
        set(value) {
            if (field == value) return
            field = value
            meshDirty = true // 网格的经度范围取决于覆盖角, 要重建
            dirty = true
        }

    /** 单眼在片源里的归一化区域 (u0, u1, v0, v1) */
    @Volatile
    var eyeRect: FloatArray = floatArrayOf(0f, 1f, 0f, 1f)
        set(value) {
            field = value
            dirty = true
        }

    /**
     * 片源 v 方向是否翻转（默认翻）。
     *
     * `SurfaceTexture.getTransformMatrix()` 各机型不统一：有的自带一次上下翻转，
     * 有的是单位阵。第六轮真机反馈"画面上下颠倒"就是没翻；
     * 做成可实时切换，换机型当场就能确认，不必为这一个符号再出一版包。
     */
    @Volatile
    var flipV: Boolean = true
        set(value) {
            field = value
            dirty = true
        }

    /**
     * 诊断模式：跳过球面投影，把解码帧原样贴出来。
     * 直通有画面 => 解码/纹理链路正常、问题在投影；仍纯色 => 问题在解码/纹理。
     */
    @Volatile
    var passthrough: Boolean = false
        set(value) {
            field = value
            dirty = true
        }

    /** 每帧**绘制前**的回调（GL 线程）。头追增量必须在这里叠加：
     *  与读取视角同一帧、同一线程，不丢帧也不用加锁。 */
    var onBeforeFrame: (() -> Unit)? = null

    var onError: ((String) -> Unit)? = null

    /** 视角/参数变了就调它，标记下一帧需要重绘 */
    fun markDirty() {
        dirty = true
    }

    // ==================== 诊断计数 ====================

    @Volatile
    var renderedFrames: Long = 0
        private set

    @Volatile
    var textureUpdates: Long = 0
        private set

    @Volatile
    var skippedFrames: Long = 0
        private set

    @Volatile
    var lastGlError: Int = 0
        private set

    @Volatile
    var renderSize: String = "0x0"
        private set

    @Volatile
    private var gotFirstFrame: Boolean = false

    /**
     * 渲染目标(EGL surface)的尺寸。
     *
     * **必须自己设**：Flutter 的 `createSurfaceTexture()` 不会替插件调
     * `setDefaultBufferSize`，默认 0x0 -> EGL 只交换出 1 个像素 ->
     * Flutter 把它拉伸铺满全屏 = 整屏一个纯色（第六轮真机就是这么翻车的）。
     */
    @Volatile
    private var renderWidth = 1280

    @Volatile
    private var renderHeight = 720

    fun setRenderSize(width: Int, height: Int) {
        if (width <= 1 || height <= 1) return
        if (width == renderWidth && height == renderHeight) return
        renderWidth = width
        renderHeight = height
        handler?.post {
            outputSurfaceTexture.setDefaultBufferSize(width, height)
            // EGL 的 window surface 可能缓存了旧几何信息, 重建一次最稳
            recreateEglSurface()
            dirty = true
        }
    }

    /** 解码器输出尺寸（只用于诊断显示） */
    @Volatile
    var videoSize: Pair<Int, Int> = Pair(0, 0)
        private set

    @Volatile
    var ready: Boolean = false
        private set

    /** 解码器要写入的 Surface；在渲染线程上创建好后才可用 */
    @Volatile
    var videoSurface: Surface? = null
        private set

    fun setVideoSize(width: Int, height: Int) {
        if (width <= 0 || height <= 0) return
        videoSize = Pair(width, height)
        handler?.post { videoSurfaceTexture?.setDefaultBufferSize(width, height) }
    }

    /** 一行诊断信息，Dart 侧可直接显示到屏幕上 */
    fun debugInfo(): String {
        val (vw, vh) = videoSize
        return "render=$renderSize video=${vw}x$vh " +
            "frames=$renderedFrames skip=$skippedFrames texUpd=$textureUpdates " +
            "glErr=0x${Integer.toHexString(lastGlError)} mesh=$meshCoverage" +
            " flipV=$flipV pass=$passthrough firstFrame=$gotFirstFrame"
    }

    // ==================== 内部状态（只在渲染线程上碰） ====================

    private var thread: HandlerThread? = null
    private var handler: Handler? = null
    private var eglDisplay: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var eglContext: EGLContext = EGL14.EGL_NO_CONTEXT
    private var eglSurface: EGLSurface = EGL14.EGL_NO_SURFACE
    private var eglConfig: EGLConfig? = null
    private var outputSurface: Surface? = null

    private var sphereProgram = 0
    private var flatProgram = 0
    private var videoTextureId = 0
    private var videoSurfaceTexture: SurfaceTexture? = null
    private val texMatrix = FloatArray(16)

    private var meshVbo = 0
    private var meshIbo = 0
    private var meshIndexCount = 0
    private var meshCoverage = 0f

    @Volatile
    private var meshDirty = true
    private var quadBuffer: FloatBuffer? = null

    private val projM = FloatArray(16)
    private val viewM = FloatArray(16)
    private val mvp = FloatArray(16)

    @Volatile
    private var dirty = true

    @Volatile
    private var frameAvailable = false

    @Volatile
    private var running = false

    private var surfaceWidth = 1
    private var surfaceHeight = 1
    private var choreographer: Choreographer? = null
    private var frameScheduled = false

    // ==================== 生命周期 ====================

    fun start() {
        if (running) return
        running = true
        val t = HandlerThread("pili-vr-gl").also { it.start() }
        thread = t
        val h = Handler(t.looper)
        handler = h
        h.post {
            try {
                initGl()
                ready = true
                choreographer = Choreographer.getInstance()
                scheduleFrame()
            } catch (e: Throwable) {
                Log.e(TAG, "init gl failed", e)
                onError?.invoke("GL 初始化失败: ${e.message}")
            }
        }
    }

    /** 等 GL 线程把 SurfaceTexture/Surface 建好；超时返回 null */
    fun awaitVideoSurface(timeoutMs: Long = 3000): Surface? {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            videoSurface?.let { return it }
            try {
                Thread.sleep(5)
            } catch (_: InterruptedException) {
                return null
            }
        }
        return videoSurface
    }

    /** 有新帧/视角变化时请求重绘（Choreographer 会合并到下一个 vsync） */
    fun requestRender() {
        dirty = true
        handler?.post { scheduleFrame() }
    }

    fun stop() {
        running = false
        ready = false
        val h = handler
        handler = null
        val t = thread
        thread = null
        h?.post { releaseGl() }
        t?.quitSafely()
        try {
            t?.join(500)
        } catch (_: InterruptedException) {
        }
        videoSurface?.release()
        videoSurface = null
    }

    // ==================== GL 初始化 ====================

    private fun initGl() {
        eglDisplay = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        if (eglDisplay == EGL14.EGL_NO_DISPLAY) throw RuntimeException("eglGetDisplay failed")
        val version = IntArray(2)
        if (!EGL14.eglInitialize(eglDisplay, version, 0, version, 1)) {
            throw RuntimeException("eglInitialize failed")
        }
        val attribs = intArrayOf(
            EGL14.EGL_RED_SIZE, 8,
            EGL14.EGL_GREEN_SIZE, 8,
            EGL14.EGL_BLUE_SIZE, 8,
            EGL14.EGL_ALPHA_SIZE, 8,
            EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
            EGL14.EGL_NONE,
        )
        val configs = arrayOfNulls<EGLConfig>(1)
        val numConfigs = IntArray(1)
        if (!EGL14.eglChooseConfig(eglDisplay, attribs, 0, configs, 0, 1, numConfigs, 0) ||
            numConfigs[0] <= 0
        ) {
            throw RuntimeException("eglChooseConfig failed")
        }
        eglConfig = configs[0]
        eglContext = EGL14.eglCreateContext(
            eglDisplay, eglConfig, EGL14.EGL_NO_CONTEXT,
            intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE), 0,
        )
        if (eglContext == EGL14.EGL_NO_CONTEXT) throw RuntimeException("eglCreateContext failed")
        // 用 Surface 包一层再交给 EGL: EGL14 对直接传 SurfaceTexture 的处理
        // 各版本不完全一致, Surface 是所有实现都认的 native window
        outputSurface = Surface(outputSurfaceTexture)
        eglSurface = EGL14.eglCreateWindowSurface(
            eglDisplay, eglConfig, outputSurface, intArrayOf(EGL14.EGL_NONE), 0,
        )
        if (eglSurface == EGL14.EGL_NO_SURFACE) throw RuntimeException("eglCreateWindowSurface failed")
        if (!EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)) {
            throw RuntimeException("eglMakeCurrent failed")
        }
        // Flutter 不会替我们设输出缓冲区尺寸, 不设就是 0x0 -> 纯色画面
        outputSurfaceTexture.setDefaultBufferSize(renderWidth, renderHeight)
        querySurfaceSize()

        sphereProgram = buildProgram(SPHERE_VS, SPHERE_FS)
        flatProgram = buildProgram(FLAT_VS, FLAT_FS)

        val quad = floatArrayOf(-1f, -1f, 1f, -1f, -1f, 1f, 1f, 1f)
        quadBuffer = ByteBuffer.allocateDirect(quad.size * FLOAT_BYTES)
            .order(ByteOrder.nativeOrder())
            .asFloatBuffer()
            .apply { put(quad); position(0) }

        // 视频纹理：OES 外部纹理（MediaCodec 输出的就是这种）
        val ids = IntArray(1)
        GLES20.glGenTextures(1, ids, 0)
        videoTextureId = ids[0]
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, videoTextureId)
        for ((pname, value) in listOf(
            GLES20.GL_TEXTURE_MIN_FILTER to GLES20.GL_LINEAR,
            GLES20.GL_TEXTURE_MAG_FILTER to GLES20.GL_LINEAR,
            GLES20.GL_TEXTURE_WRAP_S to GLES20.GL_CLAMP_TO_EDGE,
            GLES20.GL_TEXTURE_WRAP_T to GLES20.GL_CLAMP_TO_EDGE,
        )) {
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, pname, value)
        }

        // SurfaceTexture 必须在持有 EGL 上下文的线程上创建。
        // 这个构造函数虽被标记 deprecated, 但它是唯一能在指定 GL 纹理上直接
        // 建 SurfaceTexture 的方式, 且所有 API 级别都可用。
        @Suppress("DEPRECATION")
        val st = SurfaceTexture(videoTextureId)
        val (w, h) = videoSize
        if (w > 0 && h > 0) st.setDefaultBufferSize(w, h)
        Matrix.setIdentityM(texMatrix, 0)
        st.setOnFrameAvailableListener({
            frameAvailable = true
            dirty = true
            scheduleFrame()
        }, handler)
        videoSurfaceTexture = st
        videoSurface = Surface(st)

        // 相机在球内部, 要看内壁 -> 关掉背面剔除
        GLES20.glDisable(GLES20.GL_CULL_FACE)
        GLES20.glDisable(GLES20.GL_DEPTH_TEST)
        GLES20.glClearColor(0f, 0f, 0f, 1f)
    }

    // ==================== 球面网格 ====================

    /**
     * 生成 UV 球面网格（相机在球心）。
     *
     * 顶点位置用「lon=0 朝 -Z、lat=+90 朝 +Y」的约定，与
     * `view = Rx(-pitch)·Ry(-yaw)` 的视图矩阵配套（见 [computeMvp]）：
     * lon=+90（片源右侧）落在 -X，抬头时 +Y 方向的顶点进视野。
     *
     * uv 用**图像空间**（u 从左到右、v 从上到下 = 0），
     * 因此 v = 0 对应 lat=+90（片源最上面一行 = 天顶）。
     * 180° 片源就是半个球，经度范围减半，uv 仍然铺满 0..1。
     */
    private fun buildSphereMesh(coverageDeg: Float) {
        val lonSegs = if (coverageDeg >= 360f) LON_SEGS_360 else LON_SEGS_360 / 2
        val latSegs = LAT_SEGS
        val coverageRad = Math.toRadians(coverageDeg.toDouble())
        val vertices = FloatArray((lonSegs + 1) * (latSegs + 1) * 5)
        var vi = 0
        for (j in 0..latSegs) {
            val lat = Math.PI / 2 - j.toDouble() / latSegs * Math.PI // +90° .. -90°
            val v = j.toFloat() / latSegs
            val cl = cos(lat)
            val sl = sin(lat)
            for (i in 0..lonSegs) {
                val lon = -coverageRad / 2 + i.toDouble() / lonSegs * coverageRad
                val u = i.toFloat() / lonSegs
                vertices[vi++] = (-cl * sin(lon)).toFloat()
                vertices[vi++] = sl.toFloat()
                vertices[vi++] = (-cl * cos(lon)).toFloat()
                vertices[vi++] = u
                vertices[vi++] = v
            }
        }
        val indices = ShortArray(lonSegs * latSegs * 6)
        var ii = 0
        for (j in 0 until latSegs) {
            for (i in 0 until lonSegs) {
                val a = (j * (lonSegs + 1) + i).toShort()
                val b = (a + 1).toShort()
                val c = ((j + 1) * (lonSegs + 1) + i).toShort()
                val d = (c + 1).toShort()
                indices[ii++] = a
                indices[ii++] = c
                indices[ii++] = b
                indices[ii++] = b
                indices[ii++] = c
                indices[ii++] = d
            }
        }

        deleteMesh()
        val bufs = IntArray(2)
        GLES20.glGenBuffers(2, bufs, 0)
        meshVbo = bufs[0]
        meshIbo = bufs[1]
        GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, meshVbo)
        GLES20.glBufferData(
            GLES20.GL_ARRAY_BUFFER, vertices.size * FLOAT_BYTES,
            ByteBuffer.allocateDirect(vertices.size * FLOAT_BYTES)
                .order(ByteOrder.nativeOrder())
                .asFloatBuffer().apply { put(vertices); position(0) },
            GLES20.GL_STATIC_DRAW,
        )
        GLES20.glBindBuffer(GLES20.GL_ELEMENT_ARRAY_BUFFER, meshIbo)
        GLES20.glBufferData(
            GLES20.GL_ELEMENT_ARRAY_BUFFER, indices.size * 2,
            ByteBuffer.allocateDirect(indices.size * 2)
                .order(ByteOrder.nativeOrder())
                .asShortBuffer().apply { put(indices); position(0) },
            GLES20.GL_STATIC_DRAW,
        )
        GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, 0)
        GLES20.glBindBuffer(GLES20.GL_ELEMENT_ARRAY_BUFFER, 0)
        meshIndexCount = indices.size
        meshCoverage = coverageDeg
        meshDirty = false
    }

    private fun deleteMesh() {
        if (meshVbo != 0 || meshIbo != 0) {
            GLES20.glDeleteBuffers(2, intArrayOf(meshVbo, meshIbo), 0)
            meshVbo = 0
            meshIbo = 0
            meshIndexCount = 0
        }
    }

    /**
     * 每帧在 CPU 上算 MVP：透视投影(竖直 fov 由水平 fov 与宽高比换算) ×
     * 视图矩阵 `Rx(-pitch)·Ry(-yaw)`。
     *
     * 推导：网格 lon=0/lat=0 的顶点在 -Z（相机正前方），lon=+90 在 -X。
     * 要让"向右看 yaw"把 lon=+90 转到正前方，视图矩阵需绕 Y 转 -yaw；
     * 要让"抬头 pitch"把 lat=+pitch 转到正前方，需绕 X 转 -pitch。
     */
    private fun computeMvp() {
        val aspect = if (surfaceHeight > 0) {
            surfaceWidth.toFloat() / surfaceHeight.toFloat()
        } else {
            1f
        }
        val fovH = fovDeg.coerceIn(5f, 170f)
        val fovy = 2.0 * Math.toDegrees(
            atan(tan(Math.toRadians(fovH.toDouble()) / 2.0) / aspect.toDouble()),
        ).toFloat()
        Matrix.perspectiveM(projM, 0, fovy.coerceIn(1f, 179f), aspect, 0.1f, 10f)
        Matrix.setIdentityM(viewM, 0)
        Matrix.rotateM(viewM, 0, -pitchDeg, 1f, 0f, 0f)
        Matrix.rotateM(viewM, 0, -yawDeg, 0f, 1f, 0f)
        Matrix.multiplyMM(mvp, 0, projM, 0, viewM, 0)
    }

    // ==================== 帧循环 ====================

    private fun querySurfaceSize() {
        val w = IntArray(1)
        val h = IntArray(1)
        EGL14.eglQuerySurface(eglDisplay, eglSurface, EGL14.EGL_WIDTH, w, 0)
        EGL14.eglQuerySurface(eglDisplay, eglSurface, EGL14.EGL_HEIGHT, h, 0)
        // EGL 查不到(个别实现返回 0)时退回我们自己设的尺寸, 绝不能是 0/1,
        // 否则 glViewport 只有 1x1, Flutter 拉伸后就是纯色
        surfaceWidth = if (w[0] > 1) w[0] else renderWidth
        surfaceHeight = if (h[0] > 1) h[0] else renderHeight
        renderSize = "${surfaceWidth}x$surfaceHeight"
    }

    private fun recreateEglSurface() {
        if (eglDisplay == EGL14.EGL_NO_DISPLAY || eglConfig == null) return
        try {
            EGL14.eglMakeCurrent(
                eglDisplay, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, eglContext,
            )
            if (eglSurface != EGL14.EGL_NO_SURFACE) {
                EGL14.eglDestroySurface(eglDisplay, eglSurface)
            }
            eglSurface = EGL14.eglCreateWindowSurface(
                eglDisplay, eglConfig, outputSurface, intArrayOf(EGL14.EGL_NONE), 0,
            )
            EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)
            querySurfaceSize()
        } catch (e: Throwable) {
            Log.w(TAG, "recreateEglSurface: ${e.message}")
        }
    }

    private fun scheduleFrame() {
        if (!running || frameScheduled) return
        val c = choreographer ?: return
        frameScheduled = true
        c.postFrameCallback {
            frameScheduled = false
            if (!running) return@postFrameCallback
            // 头追增量在绘制前叠加(它会把 dirty 置起来)
            try {
                onBeforeFrame?.invoke()
            } catch (e: Throwable) {
                Log.w(TAG, "onBeforeFrame: ${e.message}")
            }
            if (dirty) {
                dirty = false
                drawFrame()
            } else {
                // 画面没变就不重绘: 静止时省 GPU, 也让解码线程能拿到 CPU
                skippedFrames++
            }
            scheduleFrame()
        }
    }

    private fun drawFrame() {
        if (eglSurface == EGL14.EGL_NO_SURFACE) return
        EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)
        querySurfaceSize()
        val st = videoSurfaceTexture
        if (st != null && frameAvailable) {
            frameAvailable = false
            try {
                st.updateTexImage()
                st.getTransformMatrix(texMatrix)
                textureUpdates++
                gotFirstFrame = true
            } catch (e: Throwable) {
                Log.w(TAG, "updateTexImage failed: ${e.message}")
            }
        }
        GLES20.glViewport(0, 0, surfaceWidth, surfaceHeight)
        // 一帧视频都没到时清成深蓝: 深蓝 = GL 在跑但没有解码帧,
        // 纯黑 = 连 GL 输出都没到 Flutter。两者修法完全不同, 必须能区分
        GLES20.glClearColor(0f, 0f, if (gotFirstFrame) 0f else 0.25f, 1f)
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
        if (st == null) {
            EGL14.eglSwapBuffers(eglDisplay, eglSurface)
            return
        }
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, videoTextureId)

        if (passthrough) {
            drawFlat()
        } else {
            drawSphere()
        }
        val swapped = EGL14.eglSwapBuffers(eglDisplay, eglSurface)
        renderedFrames++
        val err = GLES20.glGetError()
        if (err != GLES20.GL_NO_ERROR) lastGlError = err
        if (!swapped) {
            val eglErr = EGL14.eglGetError()
            if (eglErr != EGL14.EGL_SUCCESS) {
                Log.w(TAG, "eglSwapBuffers failed: 0x${Integer.toHexString(eglErr)}")
            }
        }
    }

    private fun drawSphere() {
        if (meshDirty || meshCoverage != coverageHDeg) buildSphereMesh(coverageHDeg)
        if (sphereProgram == 0 || meshIndexCount == 0) return
        computeMvp()
        GLES20.glUseProgram(sphereProgram)
        val posLoc = GLES20.glGetAttribLocation(sphereProgram, "aPos")
        val uvLoc = GLES20.glGetAttribLocation(sphereProgram, "aUv")
        GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, meshVbo)
        GLES20.glEnableVertexAttribArray(posLoc)
        GLES20.glVertexAttribPointer(posLoc, 3, GLES20.GL_FLOAT, false, STRIDE, 0)
        GLES20.glEnableVertexAttribArray(uvLoc)
        GLES20.glVertexAttribPointer(uvLoc, 2, GLES20.GL_FLOAT, false, STRIDE, 3 * FLOAT_BYTES)
        GLES20.glBindBuffer(GLES20.GL_ELEMENT_ARRAY_BUFFER, meshIbo)
        GLES20.glUniformMatrix4fv(
            GLES20.glGetUniformLocation(sphereProgram, "uMvp"), 1, false, mvp, 0,
        )
        GLES20.glUniformMatrix4fv(
            GLES20.glGetUniformLocation(sphereProgram, "uTexMatrix"), 1, false, texMatrix, 0,
        )
        GLES20.glUniform1i(GLES20.glGetUniformLocation(sphereProgram, "uVideo"), 0)
        GLES20.glUniform1f(
            GLES20.glGetUniformLocation(sphereProgram, "uFlipV"), if (flipV) 1f else 0f,
        )
        GLES20.glUniform4fv(
            GLES20.glGetUniformLocation(sphereProgram, "uEye"), 1, eyeRect, 0,
        )
        GLES20.glDrawElements(
            GLES20.GL_TRIANGLES, meshIndexCount, GLES20.GL_UNSIGNED_SHORT, 0,
        )
        GLES20.glDisableVertexAttribArray(posLoc)
        GLES20.glDisableVertexAttribArray(uvLoc)
        GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, 0)
        GLES20.glBindBuffer(GLES20.GL_ELEMENT_ARRAY_BUFFER, 0)
    }

    private fun drawFlat() {
        val vb = quadBuffer ?: return
        if (flatProgram == 0) return
        GLES20.glUseProgram(flatProgram)
        val posLoc = GLES20.glGetAttribLocation(flatProgram, "aPos")
        GLES20.glEnableVertexAttribArray(posLoc)
        GLES20.glVertexAttribPointer(posLoc, 2, GLES20.GL_FLOAT, false, 0, vb)
        GLES20.glUniform1i(GLES20.glGetUniformLocation(flatProgram, "uVideo"), 0)
        GLES20.glUniformMatrix4fv(
            GLES20.glGetUniformLocation(flatProgram, "uTexMatrix"), 1, false, texMatrix, 0,
        )
        GLES20.glUniform1f(
            GLES20.glGetUniformLocation(flatProgram, "uFlipV"), if (flipV) 1f else 0f,
        )
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
        GLES20.glDisableVertexAttribArray(posLoc)
    }

    private fun releaseGl() {
        try {
            videoSurfaceTexture?.release()
            videoSurfaceTexture = null
            deleteMesh()
            if (sphereProgram != 0) {
                GLES20.glDeleteProgram(sphereProgram)
                sphereProgram = 0
            }
            if (flatProgram != 0) {
                GLES20.glDeleteProgram(flatProgram)
                flatProgram = 0
            }
            if (videoTextureId != 0) {
                GLES20.glDeleteTextures(1, intArrayOf(videoTextureId), 0)
                videoTextureId = 0
            }
            if (eglDisplay != EGL14.EGL_NO_DISPLAY) {
                EGL14.eglMakeCurrent(
                    eglDisplay, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT,
                )
                if (eglSurface != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(eglDisplay, eglSurface)
                if (eglContext != EGL14.EGL_NO_CONTEXT) EGL14.eglDestroyContext(eglDisplay, eglContext)
                EGL14.eglTerminate(eglDisplay)
            }
        } catch (e: Throwable) {
            Log.w(TAG, "releaseGl: ${e.message}")
        }
        outputSurface?.release()
        outputSurface = null
        eglSurface = EGL14.EGL_NO_SURFACE
        eglContext = EGL14.EGL_NO_CONTEXT
        eglDisplay = EGL14.EGL_NO_DISPLAY
    }

    private fun buildProgram(vs: String, fs: String): Int {
        val v = compileShader(GLES20.GL_VERTEX_SHADER, vs)
        val f = compileShader(GLES20.GL_FRAGMENT_SHADER, fs)
        val p = GLES20.glCreateProgram()
        GLES20.glAttachShader(p, v)
        GLES20.glAttachShader(p, f)
        GLES20.glLinkProgram(p)
        val status = IntArray(1)
        GLES20.glGetProgramiv(p, GLES20.GL_LINK_STATUS, status, 0)
        if (status[0] == 0) {
            val log = GLES20.glGetProgramInfoLog(p)
            GLES20.glDeleteProgram(p)
            throw RuntimeException("link program failed: $log")
        }
        GLES20.glDeleteShader(v)
        GLES20.glDeleteShader(f)
        return p
    }

    private fun compileShader(type: Int, source: String): Int {
        val shader = GLES20.glCreateShader(type)
        GLES20.glShaderSource(shader, source)
        GLES20.glCompileShader(shader)
        val status = IntArray(1)
        GLES20.glGetShaderiv(shader, GLES20.GL_COMPILE_STATUS, status, 0)
        if (status[0] == 0) {
            val log = GLES20.glGetShaderInfoLog(shader)
            GLES20.glDeleteShader(shader)
            throw RuntimeException("compile shader failed: $log")
        }
        return shader
    }
}
