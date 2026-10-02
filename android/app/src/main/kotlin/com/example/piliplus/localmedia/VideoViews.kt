package com.example.piliplus.localmedia

import android.content.Context
import android.view.View
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import org.videolan.libvlc.util.VLCVideoLayout

/**
 * Registry + PlatformView factory hosting VLCVideoLayout instances so the
 * libvlc video (and its subtitle surface) can be embedded under Flutter's
 * hybrid-composition overlay controls.
 */
object VideoViews {
    private val views = HashMap<Int, VLCVideoLayout>()

    fun get(viewId: Int): VLCVideoLayout? = views[viewId]

    fun put(viewId: Int, layout: VLCVideoLayout) {
        views[viewId] = layout
    }

    fun remove(viewId: Int) {
        views.remove(viewId)
    }

    class Factory : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
        override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
            // Never crash the platform thread: fall back to an error card the
            // user can see (and that gets logged persistently).
            val view: View = try {
                val layout = VLCVideoLayout(context)
                put(viewId, layout)
                layout
            } catch (t: Throwable) {
                LogCollector.e("VideoViews", "VLCVideoLayout creation failed", t)
                android.widget.TextView(context).apply {
                    text = "视频组件初始化失败：${t.message}"
                    setTextColor(0xFFFF5252.toInt())
                    setBackgroundColor(0xFF000000.toInt())
                    setPadding(32, 32, 32, 32)
                }
            }
            return object : PlatformView {
                override fun getView(): View = view

                override fun dispose() {
                    LocalMediaPlugin.onVideoViewDisposed(viewId)
                    remove(viewId)
                }
            }
        }
    }
}
