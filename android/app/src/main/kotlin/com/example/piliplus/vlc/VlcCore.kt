package com.example.piliplus.vlc

import android.content.Context
import com.example.piliplus.LogCollector
import org.videolan.libvlc.LibVLC

/**
 * libvlc 单例。
 *
 * 引擎 = VR 补丁版 libvlc-all 3.7.6(tool/libvlc-vr 构建, docs §18):
 * 官方 AAR 换心 arm64 .so, 在官方能力(全部编解码器、smb/ftp/nfs/upnp
 * 协议、字幕渲染、360° 投影)之上增加 vr-projection/vr-layout/vr-coverage/
 * vr-eye 选项与 piliplus-vr1 changeset 标记; 其余 ABI 仍为官方原样。
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
        return try {
            LibVLC(context.applicationContext, options).also { instance = it }
        } catch (t: Throwable) {
            LogCollector.e("VlcCore", "LibVLC 初始化失败", t)
            throw t
        }
    }

    /** 进程退出前可不显式调用; 保留给未来"设置里重启 VLC 引擎"之类的需求。 */
    @Synchronized
    fun release() {
        instance?.takeIf { !it.isReleased }?.release()
        instance = null
    }
}
