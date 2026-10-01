package com.example.piliplus.vlc

import android.content.Context
import org.videolan.libvlc.LibVLC

/**
 * libvlc 单例。
 *
 * 官方 libvlc-all(3.7.6) 即 VLC 安卓 app 使用的完整引擎: 全部编解码器、
 * smb/ftp/nfs/upnp 等网络协议、字幕渲染、360° 投影都内置在 libvlc.so 里。
 *
 * 首次构造会加载 ~55MB 的 native 库(数百毫秒), 所以一律在后台线程调用 [get]。
 */
object VlcCore {

    @Volatile
    private var instance: LibVLC? = null

    /** 后台线程调用。返回可反复使用的 LibVLC 实例。 */
    @Synchronized
    fun get(context: Context): LibVLC {
        instance?.takeIf { !it.isReleased }?.let { return it }
        val options = arrayListOf(
            // 不在画面上叠加 VLC 内置的媒体标题
            "--no-video-title-show",
            // 网络缓存, 与 VLC 安卓端 network-caching 默认一致(1.5s)。
            // 局域网源随机访问廉价, 小缓存即可: seek 直接定位, 不预拉整段。
            "--network-caching=1500",
        )
        return LibVLC(context.applicationContext, options).also { instance = it }
    }

    /** 进程退出前可不显式调用; 保留给未来"设置里重启 VLC 引擎"之类的需求。 */
    @Synchronized
    fun release() {
        instance?.takeIf { !it.isReleased }?.release()
        instance = null
    }
}
