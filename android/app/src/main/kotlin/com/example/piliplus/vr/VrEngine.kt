package com.example.piliplus.vr

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import android.os.Build
import android.util.Log
import android.view.Surface
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

/**
 * VR 播放器的解码/播放引擎：MediaExtractor + MediaCodec + AudioTrack。
 *
 * 与 mpv 完全无关（真机反馈要求「VR 模式切到 xl_player 那样的播放器」）：
 * 视频解到 [Surface]（由 [VrGlPipeline] 的 SurfaceTexture 提供），
 * 由 GL 线程做球面重投影；音频走 AudioTrack，并作为**主时钟**。
 *
 * 线程模型（都用同步 API，比异步回调好推理）：
 *   * video 线程：喂 extractor 的样本 → dequeue 输出 → **等到该帧的显示时间**
 *     再 releaseOutputBuffer(render=true) → GL 线程收到 onFrameAvailable 出帧；
 *   * audio 线程：解码 → 阻塞写 AudioTrack → 用 playbackHeadPosition 更新主时钟；
 *   * 没有音轨时退化成墙钟计时（按倍速推进）。
 *
 * 已知的能力边界（都在文档里写明，不藏）：不支持外挂/内嵌字幕与多音轨切换、
 * 不支持 DRM、不支持精确到帧的 seek（对齐到前一个关键帧）。
 */
internal class VrEngine(
    private val context: Context,
    private val gl: VrGlPipeline,
) {
    companion object {
        private const val TAG = "VrEngine"
        private const val DEQUEUE_TIMEOUT_US = 10_000L
        private const val DROP_LATE_US = 60_000L
        private const val MAX_SLEEP_MS = 10L

        /**
         * 预读窗口。第七轮真机反馈"卡顿更严重了": 一次喂满输入之后解码器会
         * 尽可能往前解, 在弱 SoC 上与渲染线程抢 CPU, 反而更卡; seek 时也会
         * 白解一大堆用不上的帧。限制成"最多领先时钟 0.8 秒"就够吸收 IO 抖动了。
         */
        private const val READ_AHEAD_US = 800_000L
    }

    var onPrepared: ((durationUs: Long, hasAudio: Boolean, width: Int, height: Int) -> Unit)? = null
    var onEnded: (() -> Unit)? = null
    var onError: ((String) -> Unit)? = null
    var onBuffering: ((Boolean) -> Unit)? = null

    @Volatile
    var playing: Boolean = false
        private set

    @Volatile
    var durationUs: Long = 0L
        private set

    @Volatile
    var hasAudio: Boolean = false
        private set

    @Volatile
    var speed: Float = 1f
        private set

    /// 诊断计数: 解码器吐出的帧数 / 真正送去渲染的帧数
    @Volatile
    var decodedFrames: Long = 0
        private set

    @Volatile
    var renderedFrames: Long = 0
        private set

    // ==================== 视频 ====================
    private var videoExtractor: MediaExtractor? = null
    private var videoCodec: MediaCodec? = null
    private var videoThread: Thread? = null
    private var videoInputDone = false
    private var videoOutputDone = false

    /// 暂停状态下也放行一帧(拖动进度条时能看到画面)
    @Volatile
    private var renderOneFrame = false

    // ==================== 音频 ====================
    private var audioExtractor: MediaExtractor? = null
    private var audioCodec: MediaCodec? = null
    private var audioThread: Thread? = null
    private var audioTrack: AudioTrack? = null
    private var audioInputDone = false
    private var audioOutputDone = false
    private var audioSampleRate = 44100
    private var audioChannelCount = 2
    private var audioFrameSize = 4

    // ==================== 时钟与 seek ====================
    private val clockUs = AtomicLong(0)
    private val seekTargetUs = AtomicLong(-1)
    private val seekGeneration = AtomicInteger(0)
    private var videoSeekGen = -1
    private var audioSeekGen = -1
    private var wallClockBaseUs = 0L
    private var wallClockBaseNanos = 0L

    /// 暂停期间冻结的位置（仅无音轨时用；有音轨时 AudioTrack 停下时钟自然就不走了）
    @Volatile
    private var frozenUs: Long = -1

    // 无音轨时用墙钟推进
    private fun wallClockNowUs(): Long =
        wallClockBaseUs + ((System.nanoTime() - wallClockBaseNanos) / 1000 * speed).toLong()

    private fun positionUs(): Long = if (hasAudio) {
        clockUs.get()
    } else {
        val f = frozenUs
        if (f >= 0) f else wallClockNowUs()
    }

    private fun resyncWallClock(us: Long) {
        wallClockBaseUs = us
        wallClockBaseNanos = System.nanoTime()
    }

    // ==================== 生命周期 ====================

    @Volatile
    private var released = false

    fun open(uri: String, headers: Map<String, String>?, startPositionUs: Long) {
        try {
            val parsed = Uri.parse(uri)
            val vEx = MediaExtractor()
            videoExtractor = vEx
            setDataSource(vEx, parsed, headers)
            val videoTrackIndex = selectTrack(vEx, "video/")
            if (videoTrackIndex < 0) {
                onError?.invoke("没有找到视频轨（这个容器/编码可能不受支持）")
                return
            }
            vEx.selectTrack(videoTrackIndex)
            val format = vEx.getTrackFormat(videoTrackIndex)
            val mime = format.getString(MediaFormat.KEY_MIME)!!
            val width = format.getInteger(MediaFormat.KEY_WIDTH)
            val height = format.getInteger(MediaFormat.KEY_HEIGHT)
            durationUs = if (format.containsKey(MediaFormat.KEY_DURATION)) {
                format.getLong(MediaFormat.KEY_DURATION)
            } else {
                0L
            }
            gl.setVideoSize(width, height)

            val surface = gl.awaitVideoSurface()
            if (surface == null) {
                onError?.invoke("GL 渲染面未就绪")
                return
            }
            val codec = MediaCodec.createDecoderByType(mime)
            videoCodec = codec
            codec.configure(format, surface, null, 0)
            codec.start()

            // 音频（可选）
            val aEx = MediaExtractor()
            audioExtractor = aEx
            var audioOk = false
            try {
                setDataSource(aEx, parsed, headers)
                val audioTrackIndex = selectTrack(aEx, "audio/")
                if (audioTrackIndex >= 0) {
                    aEx.selectTrack(audioTrackIndex)
                    audioOk = prepareAudio(aEx.getTrackFormat(audioTrackIndex))
                }
            } catch (e: Throwable) {
                Log.w(TAG, "audio init failed, play without audio: ${e.message}")
                audioOk = false
            }
            hasAudio = audioOk

            if (startPositionUs > 0) {
                seekTo(startPositionUs)
            } else {
                resyncWallClock(0)
                clockUs.set(0)
            }
            onPrepared?.invoke(durationUs, hasAudio, width, height)

            videoThread = Thread({ runVideoLoop() }, "pili-vr-video").also { it.start() }
            if (hasAudio) {
                audioThread = Thread({ runAudioLoop() }, "pili-vr-audio").also { it.start() }
            }
        } catch (e: Throwable) {
            Log.e(TAG, "open failed", e)
            onError?.invoke("打开失败: ${e.message}")
        }
    }

    private fun setDataSource(ex: MediaExtractor, uri: Uri, headers: Map<String, String>?) {
        if (headers.isNullOrEmpty()) {
            ex.setDataSource(context, uri, null)
        } else {
            ex.setDataSource(context, uri, headers)
        }
    }

    /** 选第一条匹配前缀的轨；跳过封面图（有的 mp3/flac 会带一条 video/ 的封面） */
    private fun selectTrack(ex: MediaExtractor, mimePrefix: String): Int {
        for (i in 0 until ex.trackCount) {
            val f = ex.getTrackFormat(i)
            val mime = f.getString(MediaFormat.KEY_MIME) ?: continue
            if (!mime.startsWith(mimePrefix)) continue
            if (mimePrefix == "video/") {
                // 封面图通常是 mjpeg/png，且没有帧率
                if (mime.contains("mjpeg") || mime.contains("png") || mime.contains("jpeg")) continue
            }
            return i
        }
        return -1
    }

    private fun prepareAudio(format: MediaFormat): Boolean {
        val mime = format.getString(MediaFormat.KEY_MIME) ?: return false
        audioSampleRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
        audioChannelCount = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
        val codec = MediaCodec.createDecoderByType(mime)
        codec.configure(format, null, null, 0)
        codec.start()
        audioCodec = codec

        val channelConfig = if (audioChannelCount >= 2) {
            AudioFormat.CHANNEL_OUT_STEREO
        } else {
            AudioFormat.CHANNEL_OUT_MONO
        }
        val minBuf = AudioTrack.getMinBufferSize(
            audioSampleRate, channelConfig, AudioFormat.ENCODING_PCM_16BIT,
        )
        if (minBuf <= 0) return false
        val track = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
                        .build(),
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(audioSampleRate)
                        .setChannelMask(channelConfig)
                        .build(),
                )
                .setBufferSizeInBytes(minBuf * 4)
                .setTransferMode(AudioTrack.MODE_STREAM)
                .build()
        } else {
            @Suppress("DEPRECATION")
            AudioTrack(
                AudioManager.STREAM_MUSIC, audioSampleRate, channelConfig,
                AudioFormat.ENCODING_PCM_16BIT, minBuf * 4, AudioTrack.MODE_STREAM,
            )
        }
        audioFrameSize = audioChannelCount * 2
        audioTrack = track
        track.play()
        applySpeed()
        return true
    }

    fun play() {
        if (playing) return
        // 先把冻结的位置接回墙钟基准, 再清掉冻结值(顺序不能反)
        val resumeFrom = if (hasAudio) clockUs.get() else positionUs()
        resyncWallClock(resumeFrom)
        frozenUs = -1
        playing = true
        audioTrack?.let {
            try {
                it.play()
            } catch (e: IllegalStateException) {
                Log.w(TAG, "audioTrack.play: ${e.message}")
            }
        }
    }

    fun pause() {
        if (!playing) return
        playing = false
        if (!hasAudio) {
            // 墙钟不会因为暂停而停下, 必须显式冻结, 否则恢复播放时
            // 位置会一次性跳过"暂停了多久"
            frozenUs = wallClockNowUs()
        }
        audioTrack?.let {
            try {
                it.pause()
            } catch (e: IllegalStateException) {
                Log.w(TAG, "audioTrack.pause: ${e.message}")
            }
        }
    }

    fun setSpeed(value: Float) {
        speed = value.coerceIn(0.25f, 4f)
        applySpeed()
    }

    private fun applySpeed() {
        val track = audioTrack ?: return
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        try {
            track.playbackParams = track.playbackParams.setSpeed(speed)
        } catch (e: Throwable) {
            Log.w(TAG, "setSpeed failed: ${e.message}")
        }
    }

    fun seekTo(us: Long) {
        val target = us.coerceIn(0, if (durationUs > 0) durationUs else Long.MAX_VALUE)
        seekTargetUs.set(target)
        seekGeneration.incrementAndGet()
        clockUs.set(target)
        resyncWallClock(target)
        frozenUs = if (playing || hasAudio) -1 else target
        // 暂停中拖动进度条也要能看到那一帧, 放一帧出来
        renderOneFrame = true
    }

    fun getPositionUs(): Long = positionUs()

    fun release() {
        if (released) return
        released = true
        playing = false
        videoThread?.let {
            try {
                it.join(800)
            } catch (_: InterruptedException) {
            }
        }
        audioThread?.let {
            try {
                it.join(800)
            } catch (_: InterruptedException) {
            }
        }
        videoThread = null
        audioThread = null
        safeRelease(videoCodec)
        videoCodec = null
        safeRelease(audioCodec)
        audioCodec = null
        try {
            audioTrack?.stop()
        } catch (_: Throwable) {
        }
        audioTrack?.release()
        audioTrack = null
        try {
            videoExtractor?.release()
        } catch (_: Throwable) {
        }
        try {
            audioExtractor?.release()
        } catch (_: Throwable) {
        }
        videoExtractor = null
        audioExtractor = null
    }

    private fun safeRelease(codec: MediaCodec?) {
        try {
            codec?.stop()
        } catch (_: Throwable) {
        }
        try {
            codec?.release()
        } catch (_: Throwable) {
        }
    }

    // ==================== seek 处理（两个线程各自执行一次） ====================

    /** @return true 表示本次循环刚开始时做过一次 seek */
    private fun handleSeek(ex: MediaExtractor, codec: MediaCodec, isVideo: Boolean): Boolean {
        val gen = seekGeneration.get()
        val mine = if (isVideo) videoSeekGen else audioSeekGen
        if (gen == mine) return false
        val target = seekTargetUs.get()
        if (isVideo) videoSeekGen = gen else audioSeekGen = gen
        if (target < 0) return false
        try {
            codec.flush()
        } catch (e: IllegalStateException) {
            Log.w(TAG, "flush: ${e.message}")
        }
        ex.seekTo(target, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
        if (isVideo) {
            videoInputDone = false
            videoOutputDone = false
        } else {
            audioInputDone = false
            audioOutputDone = false
            audioTrack?.let {
                try {
                    it.pause(); it.flush(); if (playing) it.play()
                } catch (e: Throwable) {
                    Log.w(TAG, "audioTrack flush: ${e.message}")
                }
            }
            clockUs.set(target)
        }
        return true
    }

    /**
     * 把样本喂进解码器, 一次尽量喂满输入缓冲池。
     *
     * 第一版每个循环只喂 **一个** 输入缓冲, 而输出侧又要等到帧的显示时间才放行 ——
     * 等待期间完全不喂输入, 解码器的输入池(通常只有 4~8 个)很快被耗干,
     * 于是输出侧反复拿到 INFO_TRY_AGAIN_LATER, 表现就是真机反馈的
     * **"等待缓冲加载频繁"**(本机文件也这样, 因为瓶颈不在 IO 而在喂入节奏)。
     *
     * @param blocking 为 true 时用 [DEQUEUE_TIMEOUT_US] 等一次, 否则不等(用于
     *                 "等显示时间"的间隙里顺手补喂, 不能阻塞)
     */
    private fun feedVideoInput(
        ex: MediaExtractor,
        codec: MediaCodec,
        blocking: Boolean,
        maxBuffers: Int = 8,
    ) {
        if (videoInputDone) return
        var fed = 0
        while (fed < maxBuffers) {
            // 预读窗口: 已经超过时钟 READ_AHEAD_US 就先不喂
            val nextPts = ex.sampleTime
            if (nextPts >= 0 && nextPts - positionUs() > READ_AHEAD_US) return
            val inIndex = codec.dequeueInputBuffer(
                if (blocking && fed == 0) DEQUEUE_TIMEOUT_US else 0,
            )
            if (inIndex < 0) return
            fed++
            val buf = codec.getInputBuffer(inIndex)
            if (buf == null) {
                codec.queueInputBuffer(inIndex, 0, 0, 0, 0)
                continue
            }
            val size = ex.readSampleData(buf, 0)
            if (size < 0) {
                codec.queueInputBuffer(
                    inIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                )
                videoInputDone = true
                return
            }
            codec.queueInputBuffer(inIndex, 0, size, ex.sampleTime, 0)
            ex.advance()
        }
    }

    // ==================== 视频循环 ====================

    private fun runVideoLoop() {
        val ex = videoExtractor ?: return
        val codec = videoCodec ?: return
        val info = MediaCodec.BufferInfo()
        var starvingSince = 0L
        try {
            while (!released) {
                handleSeek(ex, codec, true)
                if (!playing && !videoOutputDone && !renderOneFrame) {
                    Thread.sleep(MAX_SLEEP_MS)
                    continue
                }
                // ---- 输入: 一次尽量喂满, 别让解码器饿着 ----
                feedVideoInput(ex, codec, blocking = true)
                // ---- 输出 ----
                val outIndex = codec.dequeueOutputBuffer(info, DEQUEUE_TIMEOUT_US)
                when {
                    outIndex >= 0 -> {
                        val pts = info.presentationTimeUs
                        val render = info.size > 0 &&
                            (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) == 0
                        if (render) decodedFrames++
                        if (render) {
                            if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                                videoOutputDone = true
                            }
                            // 等到显示时间；太晚就丢帧追赶
                            val late = positionUs() - pts
                            if (late > DROP_LATE_US) {
                                codec.releaseOutputBuffer(outIndex, false)
                                continue
                            }
                            var wait = pts - positionUs()
                            while (wait > 3000 && playing && !released &&
                                seekGeneration.get() == videoSeekGen
                            ) {
                                // 关键: 等显示时间的这段时间里继续喂输入。
                                // 第一版在这里纯 sleep, 解码器输入池被耗干 ->
                                // 下一帧 dequeue 不到输出 -> 频繁"缓冲中"
                                feedVideoInput(ex, codec, blocking = false)
                                Thread.sleep(minOf(wait / 1000, MAX_SLEEP_MS))
                                wait = pts - positionUs()
                            }
                            if (released) {
                                codec.releaseOutputBuffer(outIndex, false)
                                break
                            }
                            codec.releaseOutputBuffer(outIndex, true)
                            renderedFrames++
                            renderOneFrame = false
                            gl.requestRender()
                            if (starvingSince != 0L) {
                                starvingSince = 0
                                onBuffering?.invoke(false)
                            }
                            if (videoOutputDone && (!hasAudio || audioOutputDone)) {
                                onEnded?.invoke()
                                break
                            }
                        } else {
                            codec.releaseOutputBuffer(outIndex, false)
                        }
                        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                            videoOutputDone = true
                            if (!hasAudio || audioOutputDone) onEnded?.invoke()
                            break
                        }
                    }
                    outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        val f = codec.outputFormat
                        if (f.containsKey(MediaFormat.KEY_WIDTH)) {
                            gl.setVideoSize(
                                f.getInteger(MediaFormat.KEY_WIDTH),
                                f.getInteger(MediaFormat.KEY_HEIGHT),
                            )
                        }
                    }
                    outIndex == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                        if (!videoInputDone && playing) {
                            val now = System.currentTimeMillis()
                            if (starvingSince == 0L) starvingSince = now
                            else if (now - starvingSince > 400) onBuffering?.invoke(true)
                        }
                    }
                }
            }
        } catch (e: Throwable) {
            if (!released) {
                Log.e(TAG, "video loop error", e)
                onError?.invoke("视频解码出错: ${e.message}")
            }
        }
    }

    /** 音频侧同理: 一次尽量喂满, AudioTrack 的阻塞写才是节奏来源 */
    private fun feedAudioInput(ex: MediaExtractor, codec: MediaCodec) {
        if (audioInputDone) return
        var fed = 0
        while (fed < 8) {
            val inIndex = codec.dequeueInputBuffer(
                if (fed == 0) DEQUEUE_TIMEOUT_US else 0,
            )
            if (inIndex < 0) return
            fed++
            val buf = codec.getInputBuffer(inIndex)
            if (buf == null) {
                codec.queueInputBuffer(inIndex, 0, 0, 0, 0)
                continue
            }
            val size = ex.readSampleData(buf, 0)
            if (size < 0) {
                codec.queueInputBuffer(
                    inIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                )
                audioInputDone = true
                return
            }
            codec.queueInputBuffer(inIndex, 0, size, ex.sampleTime, 0)
            ex.advance()
        }
    }

    // ==================== 音频循环（主时钟） ====================

    private fun runAudioLoop() {
        val ex = audioExtractor ?: return
        val codec = audioCodec ?: return
        val track = audioTrack ?: return
        val info = MediaCodec.BufferInfo()
        var anchorPtsUs = -1L
        try {
            while (!released) {
                if (handleSeek(ex, codec, false)) {
                    anchorPtsUs = -1
                }
                if (!playing) {
                    Thread.sleep(MAX_SLEEP_MS)
                    continue
                }
                feedAudioInput(ex, codec)
                val outIndex = codec.dequeueOutputBuffer(info, DEQUEUE_TIMEOUT_US)
                if (outIndex >= 0) {
                    if (info.size > 0 &&
                        (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) == 0
                    ) {
                        val buf = codec.getOutputBuffer(outIndex)
                        if (buf != null) {
                            if (anchorPtsUs < 0) anchorPtsUs = info.presentationTimeUs
                            var writtenTotal = 0
                            while (writtenTotal < info.size && !released) {
                                // 每次都从原缓冲 duplicate 一份并显式设好 position/limit:
                                // AudioTrack.write(ByteBuffer) 会推进传入缓冲的 position,
                                // 而输出缓冲的初始 position/limit 各机型不完全一致
                                val slice = buf.duplicate()
                                slice.clear()
                                slice.position(info.offset + writtenTotal)
                                slice.limit(info.offset + info.size)
                                val n = track.write(
                                    slice, slice.remaining(), AudioTrack.WRITE_BLOCKING,
                                )
                                if (n <= 0) break
                                writtenTotal += n
                            }
                            // 主时钟 = 锚点 pts + 已经真正播出去的时长
                            val playedFrames = track.playbackHeadPosition.toLong() and 0xFFFFFFFFL
                            clockUs.set(
                                anchorPtsUs + playedFrames * 1_000_000L / audioSampleRate,
                            )
                        }
                    }
                    codec.releaseOutputBuffer(outIndex, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                        audioOutputDone = true
                        if (videoOutputDone) onEnded?.invoke()
                        break
                    }
                } else if (outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    val f = codec.outputFormat
                    if (f.containsKey(MediaFormat.KEY_SAMPLE_RATE)) {
                        audioSampleRate = f.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                    }
                    if (f.containsKey(MediaFormat.KEY_CHANNEL_COUNT)) {
                        audioChannelCount = f.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                    }
                }
            }
        } catch (e: Throwable) {
            if (!released) {
                Log.e(TAG, "audio loop error", e)
                onError?.invoke("音频解码出错: ${e.message}")
            }
        }
    }
}
