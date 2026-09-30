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

/**
 * 自研 VR 渲染管线：EGL + GLES2 + SurfaceTexture。
 *
 * 为什么要有它（对应真机反馈「VR 模式应该切到 xl_player 那样的播放器而不是 mpv」）：
 * mpv 的 `vo=gpu` 用户着色器**不支持 `//!PARAM`**，视角参数只能烘焙进源码，
 * 于是「改视角 = 换源码 = 重建整条渲染管线 + 重新编译一份 GLSL」，而且
 * `gpu/video.c: load_cached_file()` 还按路径永久缓存文件内容 —— 这条路做不到
 * xl_player 那样的逐帧头追。
 *
 * 这里改成和 xl_player 同构的管线：
 * ```
 * MediaCodec 硬解 -> SurfaceTexture(OES 纹理) -> 自己的 GLES2 程序
 *                                              -> Flutter TextureRegistry 的 SurfaceTexture
 * ```
 * yaw / pitch / fov / 眼位 / 覆盖角全部是 **uniform**，每帧直接改，
 * 不重编译、不重建管线，所以陀螺仪和拖拽都能逐帧跟手。
 *
 * 画面用「全屏四边形 + 片元着色器做等距柱状→直线投影」实现（不是球面网格）：
 * 数学与 [VrShader](../../../../lib/plugin/pl_player/utils/vr_shader.dart) 完全一致，
 * 只是参数从 `#define` 变成了 uniform。相比球面网格，它没有网格密度不足导致的
 * 边缘拉伸，也不用生成/上传顶点缓冲。
 *
 * 线程模型：一个 [HandlerThread] 上跑 EGL 上下文，用 [Choreographer] 跟着
 * vsync 出帧；[SurfaceTexture] 必须始终在这个线程上 attach/updateTexImage。
 */
internal class VrGlPipeline(
    /** Flutter 侧 `TextureRegistry.createSurfaceTexture()` 给的输出目标 */
    private val outputSurfaceTexture: SurfaceTexture,
) {
    companion object {
        private const val TAG = "VrGlPipeline"

        private const val VERTEX_SHADER = """
            attribute vec2 aPos;
            varying vec2 vUv;
            void main() {
              vUv = aPos * 0.5 + 0.5;
              gl_Position = vec4(aPos, 0.0, 1.0);
            }
        """

        /**
         * 等距柱状（equirectangular）→ 直线（rectilinear）投影。
         *
         * 坐标约定与 Dart 侧保持一致：**yaw+ = 向右看，pitch+ = 向上看**，
         * `v = 0` 是片源图像的最上面一行（纬度 +90）。
         * `uTexMatrix` 是 `SurfaceTexture.getTransformMatrix()` 给的，
         * 负责把「图像空间」的 uv 映射到真正的纹理坐标（含硬件的上下翻转），
         * 所以这里必须过一遍它，不能直接采样。
         */
        private const val FRAGMENT_SHADER = """
            #extension GL_OES_EGL_image_external : require
            precision highp float;
            varying vec2 vUv;
            uniform samplerExternalOES uVideo;
            uniform mat4 uTexMatrix;
            uniform float uYaw;
            uniform float uPitch;
            uniform float uFov;
            uniform float uAspect;
            uniform float uCoverageH;
            uniform vec4 uEye;
            const float PI = 3.14159265358979;

            vec3 rotX(vec3 v, float a) {
              float c = cos(a);
              float s = sin(a);
              return vec3(v.x, c * v.y - s * v.z, s * v.y + c * v.z);
            }

            vec3 rotY(vec3 v, float a) {
              float c = cos(a);
              float s = sin(a);
              return vec3(c * v.x + s * v.z, v.y, -s * v.x + c * v.z);
            }

            void main() {
              float tanH = tan(radians(uFov) * 0.5);
              float tanV = tanH / max(uAspect, 0.01);
              vec2 sc = (vUv - 0.5) * 2.0;
              // GL 的 vUv.y 向上为正: 屏幕上方对应更高的纬度
              vec3 dir = normalize(vec3(sc.x * tanH, sc.y * tanV, 1.0));
              // 先俯仰后偏航, 俯仰不会引入滚转
              dir = rotX(dir, radians(-uPitch));
              dir = rotY(dir, radians(uYaw));
              float lon = atan(dir.x, dir.z);
              float lat = asin(clamp(dir.y, -1.0, 1.0));
              float u = lon / radians(uCoverageH) + 0.5;
              float v = 0.5 - lat / PI;
              if (uCoverageH >= 360.0) {
                u = fract(u);
              } else {
                u = clamp(u, 0.0, 1.0);
              }
              v = clamp(v, 0.0, 1.0);
              // 双目片源只取一只眼睛
              u = mix(uEye.x, uEye.y, u);
              v = mix(uEye.z, uEye.w, v);
              vec2 tuv = (uTexMatrix * vec4(u, v, 0.0, 1.0)).xy;
              gl_FragColor = texture2D(uVideo, tuv);
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

    /** 单眼在片源里的归一化区域 (u0, u1, v0, v1) */
    @Volatile
    var eyeRect: FloatArray = floatArrayOf(0f, 1f, 0f, 1f)

    /**
     * 每帧**绘制前**的回调（在 GL 线程上）。
     *
     * 头追增量必须在这里叠加到 yaw/pitch 上：它和读取视角发生在同一帧、
     * 同一个线程，既不丢帧也不用加锁，这正是"逐帧跟手"的关键。
     */
    var onBeforeFrame: (() -> Unit)? = null

    /** 解码器要写入的 Surface；在渲染线程上创建好后才可用 */
    @Volatile
    var videoSurface: Surface? = null
        private set

    @Volatile
    var videoSize: Pair<Int, Int> = Pair(0, 0)
        private set

    @Volatile
    var ready: Boolean = false
        private set

    var onError: ((String) -> Unit)? = null

    // ==================== 内部状态（只在渲染线程上碰） ====================

    private var thread: HandlerThread? = null
    private var handler: Handler? = null
    private var eglDisplay: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var eglContext: EGLContext = EGL14.EGL_NO_CONTEXT
    private var eglSurface: EGLSurface = EGL14.EGL_NO_SURFACE
    private var eglConfig: EGLConfig? = null
    private var program = 0
    private var videoTextureId = 0
    private var videoSurfaceTexture: SurfaceTexture? = null
    private val texMatrix = FloatArray(16)
    private var vertexBuffer: FloatBuffer? = null
    private var posLocation = 0
    private var texMatrixLocation = 0
    private var yawLocation = 0
    private var pitchLocation = 0
    private var fovLocation = 0
    private var aspectLocation = 0
    private var coverageLocation = 0
    private var eyeLocation = 0

    @Volatile
    private var frameAvailable = false

    @Volatile
    private var running = false

    private var surfaceWidth = 1
    private var surfaceHeight = 1
    private var choreographer: Choreographer? = null

    /** 解码器格式变化时由外部调用（任意线程），下一帧生效 */
    fun setVideoSize(width: Int, height: Int) {
        if (width <= 0 || height <= 0) return
        videoSize = Pair(width, height)
        handler?.post {
            videoSurfaceTexture?.setDefaultBufferSize(width, height)
        }
    }

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
                startFrameLoop()
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
        // 给 GL 线程一点时间收尾，然后强制退出
        t?.quitSafely()
        try {
            t?.join(500)
        } catch (_: InterruptedException) {
        }
        videoSurface?.release()
        videoSurface = null
    }

    // ==================== GL ====================

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
        eglSurface = EGL14.eglCreateWindowSurface(
            eglDisplay, eglConfig, outputSurfaceTexture, intArrayOf(EGL14.EGL_NONE), 0,
        )
        if (eglSurface == EGL14.EGL_NO_SURFACE) throw RuntimeException("eglCreateWindowSurface failed")
        if (!EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)) {
            throw RuntimeException("eglMakeCurrent failed")
        }
        querySurfaceSize()

        program = buildProgram()
        posLocation = GLES20.glGetAttribLocation(program, "aPos")
        texMatrixLocation = GLES20.glGetUniformLocation(program, "uTexMatrix")
        yawLocation = GLES20.glGetUniformLocation(program, "uYaw")
        pitchLocation = GLES20.glGetUniformLocation(program, "uPitch")
        fovLocation = GLES20.glGetUniformLocation(program, "uFov")
        aspectLocation = GLES20.glGetUniformLocation(program, "uAspect")
        coverageLocation = GLES20.glGetUniformLocation(program, "uCoverageH")
        eyeLocation = GLES20.glGetUniformLocation(program, "uEye")

        val quad = floatArrayOf(-1f, -1f, 1f, -1f, -1f, 1f, 1f, 1f)
        vertexBuffer = ByteBuffer.allocateDirect(quad.size * 4)
            .order(ByteOrder.nativeOrder())
            .asFloatBuffer()
            .apply { put(quad); position(0) }

        // 视频纹理：OES 外部纹理（MediaCodec 输出的就是这种）
        val ids = IntArray(1)
        GLES20.glGenTextures(1, ids, 0)
        videoTextureId = ids[0]
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, videoTextureId)
        GLES20.glTexParameteri(
            GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
            GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR,
        )
        GLES20.glTexParameteri(
            GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
            GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR,
        )
        GLES20.glTexParameteri(
            GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
            GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE,
        )
        GLES20.glTexParameteri(
            GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
            GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE,
        )

        // SurfaceTexture 必须在持有 EGL 上下文的线程上创建。
        // 这个构造函数虽然被标记 deprecated，但它是唯一能在指定 GL 纹理上
        // 直接建 SurfaceTexture 的方式，且所有 API 级别都可用。
        @Suppress("DEPRECATION")
        val st = SurfaceTexture(videoTextureId)
        val (w, h) = videoSize
        if (w > 0 && h > 0) st.setDefaultBufferSize(w, h)
        Matrix.setIdentityM(texMatrix, 0)
        st.setOnFrameAvailableListener({
            frameAvailable = true
            scheduleFrame()
        }, handler)
        videoSurfaceTexture = st
        videoSurface = Surface(st)
        GLES20.glClearColor(0f, 0f, 0f, 1f)
    }

    private fun querySurfaceSize() {
        val w = IntArray(1)
        val h = IntArray(1)
        EGL14.eglQuerySurface(eglDisplay, eglSurface, EGL14.EGL_WIDTH, w, 0)
        EGL14.eglQuerySurface(eglDisplay, eglSurface, EGL14.EGL_HEIGHT, h, 0)
        if (w[0] > 0) surfaceWidth = w[0]
        if (h[0] > 0) surfaceHeight = h[0]
    }

    private fun startFrameLoop() {
        val c = Choreographer.getInstance()
        choreographer = c
        scheduleFrame()
    }

    private var frameScheduled = false

    private fun scheduleFrame() {
        if (!running || frameScheduled) return
        val c = choreographer ?: return
        frameScheduled = true
        c.postFrameCallback {
            frameScheduled = false
            if (!running) return@postFrameCallback
            drawFrame()
            // 头追/拖拽时视角一直在变，保持连续出帧；没有新帧也要重绘，
            // 否则「画面不动就不刷新」会让陀螺仪看起来失灵
            scheduleFrame()
        }
    }

    private fun drawFrame() {
        if (eglSurface == EGL14.EGL_NO_SURFACE) return
        // 先把这一帧的视角算出来（头追增量），再取 uniform
        try {
            onBeforeFrame?.invoke()
        } catch (e: Throwable) {
            Log.w(TAG, "onBeforeFrame: ${e.message}")
        }
        EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)
        querySurfaceSize()
        val st = videoSurfaceTexture
        if (st != null && frameAvailable) {
            frameAvailable = false
            try {
                st.updateTexImage()
                st.getTransformMatrix(texMatrix)
            } catch (e: Throwable) {
                Log.w(TAG, "updateTexImage failed: ${e.message}")
            }
        }
        GLES20.glViewport(0, 0, surfaceWidth, surfaceHeight)
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
        if (program == 0 || st == null) {
            EGL14.eglSwapBuffers(eglDisplay, eglSurface)
            return
        }
        GLES20.glUseProgram(program)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, videoTextureId)
        GLES20.glUniform1i(GLES20.glGetUniformLocation(program, "uVideo"), 0)
        GLES20.glUniformMatrix4fv(texMatrixLocation, 1, false, texMatrix, 0)
        GLES20.glUniform1f(yawLocation, yawDeg)
        GLES20.glUniform1f(pitchLocation, pitchDeg)
        GLES20.glUniform1f(fovLocation, fovDeg)
        GLES20.glUniform1f(aspectLocation, surfaceWidth.toFloat() / surfaceHeight.toFloat())
        GLES20.glUniform1f(coverageLocation, coverageHDeg)
        GLES20.glUniform4fv(eyeLocation, 1, eyeRect, 0)

        vertexBuffer?.let { vb ->
            GLES20.glEnableVertexAttribArray(posLocation)
            GLES20.glVertexAttribPointer(posLocation, 2, GLES20.GL_FLOAT, false, 0, vb)
            GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
            GLES20.glDisableVertexAttribArray(posLocation)
        }
        EGL14.eglSwapBuffers(eglDisplay, eglSurface)
    }

    private fun releaseGl() {
        try {
            videoSurfaceTexture?.release()
            videoSurfaceTexture = null
            if (program != 0) {
                GLES20.glDeleteProgram(program)
                program = 0
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
        eglSurface = EGL14.EGL_NO_SURFACE
        eglContext = EGL14.EGL_NO_CONTEXT
        eglDisplay = EGL14.EGL_NO_DISPLAY
    }

    private fun buildProgram(): Int {
        val vs = compileShader(GLES20.GL_VERTEX_SHADER, VERTEX_SHADER)
        val fs = compileShader(GLES20.GL_FRAGMENT_SHADER, FRAGMENT_SHADER)
        val p = GLES20.glCreateProgram()
        GLES20.glAttachShader(p, vs)
        GLES20.glAttachShader(p, fs)
        GLES20.glLinkProgram(p)
        val status = IntArray(1)
        GLES20.glGetProgramiv(p, GLES20.GL_LINK_STATUS, status, 0)
        if (status[0] == 0) {
            val log = GLES20.glGetProgramInfoLog(p)
            GLES20.glDeleteProgram(p)
            throw RuntimeException("link program failed: $log")
        }
        GLES20.glDeleteShader(vs)
        GLES20.glDeleteShader(fs)
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
