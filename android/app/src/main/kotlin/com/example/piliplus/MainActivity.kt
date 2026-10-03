package com.example.piliplus

import android.content.Intent
import android.content.res.Configuration
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.view.KeyEvent
import android.view.WindowManager.LayoutParams
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        if (AndroidHelper.isFoldable) {
            AndroidHelper.ToDart.onConfigurationChanged?.run()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            window.attributes.layoutInDisplayCutoutMode =
                LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "piliplus/local_media"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                // 「本地」媒体库的系统媒体索引聚合(对齐 VLC 的媒体库数据源:
                // 按内容识别的索引, 而非扩展名过滤的目录遍历)。
                // 查询在后台线程跑, 结果必须回主线程(MethodChannel 约定)。
                "queryMediaFolders" -> {
                    val handler = Handler(Looper.getMainLooper())
                    Thread {
                        val out = try {
                            queryMediaFolders()
                        } catch (e: Exception) {
                            null
                        }
                        handler.post {
                            if (out != null) {
                                result.success(out)
                            } else {
                                result.error("query_failed", "MediaStore query failed", null)
                            }
                        }
                    }.start()
                }
                else -> result.notImplemented()
            }
        }
    }

    /// 聚合 MediaStore 的视频+音频条目为「文件夹 → (数量, 总大小, 最新修改)」。
    /// DATA 为空的条目(极少数扫描器产物)直接跳过; 目录取文件路径的父级。
    private fun queryMediaFolders(): List<Map<String, Any>> {
        // path -> [count, totalSize, latestMillis]
        val folders = HashMap<String, LongArray>()
        val projection = arrayOf(
            MediaStore.MediaColumns.DATA,
            MediaStore.MediaColumns.SIZE,
            MediaStore.MediaColumns.DATE_MODIFIED
        )
        val uris = listOf(
            MediaStore.Video.Media.EXTERNAL_CONTENT_URI,
            MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
        )
        for (uri in uris) {
            contentResolver.query(uri, projection, null, null, null)?.use { c ->
                val iData = c.getColumnIndexOrThrow(MediaStore.MediaColumns.DATA)
                val iSize = c.getColumnIndexOrThrow(MediaStore.MediaColumns.SIZE)
                val iDate = c.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_MODIFIED)
                while (c.moveToNext()) {
                    val data = c.getString(iData) ?: continue
                    val sep = data.lastIndexOf('/')
                    if (sep <= 0) continue
                    val dir = data.substring(0, sep)
                    val agg = folders.getOrPut(dir) { LongArray(3) }
                    agg[0] += 1
                    agg[1] += c.getLong(iSize)
                    val m = c.getLong(iDate) * 1000L
                    if (m > agg[2]) agg[2] = m
                }
            }
        }
        return folders.entries.map { (k, v) ->
            mapOf<String, Any>(
                "path" to k,
                "count" to v[0],
                "totalSize" to v[1],
                "latest" to v[2]
            )
        }
    }

    override fun onDestroy() {
        stopService(Intent(this, com.ryanheise.audioservice.AudioService::class.java))
        super.onDestroy()
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        AndroidHelper.ToDart.onUserLeaveHint?.run()
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration?) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        AndroidHelper.isPipMode = isInPictureInPictureMode
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        val keyCode = event.keyCode

        if (keyCode == KeyEvent.KEYCODE_BUTTON_B || keyCode == KeyEvent.KEYCODE_BUTTON_C) {
            val backEvent = KeyEvent(
                event.downTime, event.eventTime, event.action,
                KeyEvent.KEYCODE_BACK, event.repeatCount, event.metaState,
                event.deviceId, event.scanCode, event.flags, event.source
            )
            return super.dispatchKeyEvent(backEvent)
        }

        if (keyCode == KeyEvent.KEYCODE_BUTTON_MODE || keyCode == KeyEvent.KEYCODE_BUTTON_START) {
            if (event.action == KeyEvent.ACTION_DOWN) {
                moveTaskToBack(true) 
            }
            return true 
        }

        return super.dispatchKeyEvent(event)
    }
}
