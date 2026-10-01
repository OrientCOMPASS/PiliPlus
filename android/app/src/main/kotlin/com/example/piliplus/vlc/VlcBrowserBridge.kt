package com.example.piliplus.vlc

import android.content.Context
import com.example.piliplus.LogCollector
import android.net.Uri
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.videolan.libvlc.interfaces.IMedia
import org.videolan.libvlc.util.Dumper
import org.videolan.libvlc.util.MediaBrowser
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * VLC 网络浏览的 Flutter 桥(MethodChannel `piliplus/vlc_browser`)。
 *
 * 用 libvlc 自带的 [MediaBrowser] 做局域网发现与目录浏览 —— smb/ftp/nfs/upnp
 * 全部由 VLC 的 access 模块原生处理(与 VLC 安卓端同一实现), 不再需要
 * Dart 侧的 SMB2 客户端和回环 HTTP 代理。
 *
 * 事件通过同一 channel 反向推送: `onItem` / `onBrowseEnd` / `onError`。
 * 一次只有一个活动浏览会话, 新会话开始作废旧会话的事件(token 判别)。
 */
class VlcBrowserBridge(
    private val context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "piliplus/vlc_browser"
        private const val TAG = "VlcBrowserBridge"
    }

    private val channel = MethodChannel(messenger, CHANNEL)
    private val main = Handler(Looper.getMainLooper())
    private val worker: ExecutorService = Executors.newSingleThreadExecutor()

    private var browser: MediaBrowser? = null
    private var dumper: Dumper? = null
    private var sessionToken = 0
    private var disposed = false

    init {
        channel.setMethodCallHandler(this)
    }

    fun dispose() {
        if (disposed) return
        disposed = true
        channel.setMethodCallHandler(null)
        worker.execute {
            releaseBrowser()
            try { dumper?.cancel() } catch (_: Throwable) {}
            dumper = null
        }
        worker.shutdown()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            // 发现局域网 SMB 共享(VLC「网络」页同款)
            "discoverShares" -> startBrowse(result, discover = true, uri = null, showHidden = false)
            // 浏览一个目录 URI(smb://host/share/path、ftp://…、file:///…)
            "browse" -> {
                val uri = call.argument<String>("uri")
                if (uri.isNullOrEmpty()) {
                    result.error("bad_args", "uri is required", null)
                    return
                }
                startBrowse(
                    result,
                    discover = false,
                    uri = uri,
                    showHidden = call.argument<Boolean>("showHidden") ?: false,
                )
            }
            "stop" -> {
                sessionToken++
                worker.execute { releaseBrowser() }
                result.success(null)
            }
            // 下载网络文件到本机(libvlc Dumper, 替代原 Dart SMB 下载)
            "dump" -> {
                val uri = call.argument<String>("uri")
                val dest = call.argument<String>("dest")
                if (uri.isNullOrEmpty() || dest.isNullOrEmpty()) {
                    result.error("bad_args", "uri/dest required", null)
                    return
                }
                worker.execute {
                    try {
                        dumper?.cancel()
                        val d = Dumper(Uri.parse(uri), dest, object : Dumper.Listener {
                            override fun onProgress(progress: Float) {
                                emit(0, "onDumpProgress", mapOf("progress" to progress))
                            }

                            override fun onFinish(success: Boolean) {
                                dumper = null
                                emit(0, "onDumpFinished", mapOf("ok" to success))
                            }
                        })
                        dumper = d
                        d.start()
                    } catch (e: Throwable) {
                        LogCollector.e(TAG, "dump failed", e)
                        emit(0, "onDumpFinished", mapOf("ok" to false))
                    }
                }
                result.success(null)
            }
            "cancelDump" -> {
                worker.execute {
                    try { dumper?.cancel() } catch (_: Throwable) {}
                    dumper = null
                }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun startBrowse(
        result: MethodChannel.Result,
        discover: Boolean,
        uri: String?,
        showHidden: Boolean,
    ) {
        val token = ++sessionToken
        result.success(null)
        worker.execute {
            try {
                releaseBrowser()
                val listener = object : MediaBrowser.EventListener {
                    override fun onMediaAdded(index: Int, m: IMedia) {
                        val item = describe(m)
                        emit(token, "onItem", item)
                    }

                    override fun onMediaRemoved(index: Int, m: IMedia) = Unit

                    override fun onBrowseEnd() {
                        emit(token, "onBrowseEnd", null)
                    }
                }
                val b = MediaBrowser(VlcCore.get(context), listener)
                browser = b
                if (discover) {
                    b.discoverNetworkShares()
                } else {
                    var flags = 0
                    if (showHidden) flags = flags or MediaBrowser.Flag.ShowHiddenFiles
                    b.browse(Uri.parse(uri), flags)
                }
            } catch (e: Throwable) {
                LogCollector.e(TAG, "browse failed", e)
                emit(token, "onError", mapOf("message" to "${e.message}"))
            }
        }
    }

    private fun describe(m: IMedia): Map<String, Any> {
        val u = m.uri
        var name: String? = null
        try {
            name = m.getMeta(IMedia.Meta.Title)
        } catch (_: Throwable) {}
        if (name.isNullOrEmpty()) {
            name = u?.lastPathSegment?.takeIf { it.isNotEmpty() }
                ?: u?.pathSegments?.lastOrNull { it.isNotEmpty() }
                ?: u?.host?.takeIf { it.isNotEmpty() }
                ?: u?.toString()
                ?: "?"
        }
        var isDir = false
        try {
            isDir = m.getType() == IMedia.Type.Directory
        } catch (_: Throwable) {}
        // smb 目录 URI 通常以 / 结尾, 双保险
        if (!isDir && u?.toString()?.endsWith("/") == true && u.scheme != "file") {
            isDir = true
        }
        var durationMs = 0L
        try {
            durationMs = m.getDuration()
        } catch (_: Throwable) {}
        return mapOf(
            "name" to name,
            "uri" to (u?.toString() ?: ""),
            "isDir" to isDir,
            "durationMs" to durationMs,
        )
    }

    private fun releaseBrowser() {
        browser?.let {
            try {
                it.release()
            } catch (_: Throwable) {}
        }
        browser = null
    }

    private fun emit(token: Int, name: String, args: Any?) {
        if (disposed) return
        main.post {
            // token < 0: 与会话无关的事件(下载进度), 总是投递
            if (token >= 0 && token != sessionToken) return@post
            try {
                channel.invokeMethod(name, args)
            } catch (_: Throwable) {}
        }
    }
}
