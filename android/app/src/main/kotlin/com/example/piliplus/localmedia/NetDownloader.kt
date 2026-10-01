package com.example.piliplus.localmedia

import android.content.Context
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Handler
import android.os.Looper
import org.videolan.libvlc.util.Dumper
import java.io.File
import java.util.concurrent.atomic.AtomicInteger

/**
 * Downloads a network URL to local storage via libvlc's Dumper
 * (works for smb/ftp/nfs/webdav/http(s) — anything libvlc can read).
 *
 * Events:
 *  {type:"downloadProgress", id, progress}
 *  {type:"downloadDone", id, ok, path?, error?}
 */
class NetDownloader(private val context: Context) {

    private val main = Handler(Looper.getMainLooper())
    private val nextId = AtomicInteger(1)
    private val active = HashMap<Int, Dumper>()
    private var emit: ((Map<String, Any?>) -> Unit)? = null

    fun setEmitter(sink: (Map<String, Any?>) -> Unit) {
        emit = sink
    }

    fun start(url: String, destDir: String, fileName: String): Int {
        val id = nextId.getAndIncrement()
        main.post {
            try {
                VlcEngine.ensureInit(context)
                val dir = File(destDir)
                if (!dir.exists()) dir.mkdirs()
                var target = File(dir, fileName)
                var n = 1
                while (target.exists()) {
                    val base = fileName.substringBeforeLast('.')
                    val ext = if (fileName.contains('.')) "." + fileName.substringAfterLast('.') else ""
                    target = File(dir, "$base($n)$ext")
                    n++
                }
                val path = target.absolutePath
                val dumper = Dumper(Uri.parse(url), path, object : Dumper.Listener {
                    override fun onFinish(success: Boolean) {
                        active.remove(id)
                        if (success) {
                            // Make it show up in the system media index.
                            MediaScannerConnection.scanFile(
                                context, arrayOf(path), null, null
                            )
                        } else {
                            runCatching { File(path).delete() }
                        }
                        LogCollector.i(
                            "NetDownloader",
                            "download ${if (success) "finished" else "FAILED"}: " +
                                NetBrowser.redact(url)
                        )
                        main.post {
                            emit?.invoke(
                                mapOf(
                                    "type" to "downloadDone", "id" to id, "ok" to success,
                                    "path" to if (success) path else null,
                                    "error" to if (success) null else "dump failed"
                                )
                            )
                        }
                    }

                    override fun onProgress(progress: Float) {
                        main.post {
                            emit?.invoke(
                                mapOf(
                                    "type" to "downloadProgress", "id" to id,
                                    "progress" to progress.toDouble()
                                )
                            )
                        }
                    }
                })
                active[id] = dumper
                LogCollector.i("NetDownloader", "download started: ${NetBrowser.redact(url)} -> $path")
                dumper.start()
            } catch (t: Throwable) {
                LogCollector.e("NetDownloader", "download start failed: ${NetBrowser.redact(url)}", t)
                active.remove(id)
                main.post {
                    emit?.invoke(
                        mapOf(
                            "type" to "downloadDone", "id" to id, "ok" to false,
                            "error" to t.toString()
                        )
                    )
                }
            }
        }
        return id
    }

    fun cancel(id: Int) {
        main.post {
            active.remove(id)?.let {
                runCatching { it.cancel() }
            }
        }
    }

    fun release() {
        main.post {
            active.values.forEach { runCatching { it.cancel() } }
            active.clear()
        }
    }
}
