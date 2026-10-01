package com.example.piliplus

import android.content.Intent
import android.content.res.Configuration
import android.os.Build
import android.os.Bundle
import android.view.KeyEvent
import android.view.WindowManager.LayoutParams
import com.example.piliplus.vlc.VlcBrowserBridge
import com.example.piliplus.vlc.VlcLibraryBridge
import com.example.piliplus.vlc.VlcPlayerBridge
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : AudioServiceActivity() {

    /// VLC 引擎的三个桥(本地/局域网媒体: 播放 / 网络浏览 / 媒体库),
    /// 见 `vlc/` 目录与 docs/piliplayer.md §17。
    private var vlcPlayer: VlcPlayerBridge? = null
    private var vlcBrowser: VlcBrowserBridge? = null
    private var vlcLibrary: VlcLibraryBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        vlcPlayer = VlcPlayerBridge(this, messenger, flutterEngine.renderer)
        vlcBrowser = VlcBrowserBridge(this, messenger)
        vlcLibrary = VlcLibraryBridge(this, messenger)
    }

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

    override fun onDestroy() {
        vlcPlayer?.dispose()
        vlcBrowser?.dispose()
        vlcLibrary?.dispose()
        vlcPlayer = null
        vlcBrowser = null
        vlcLibrary = null
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
