package com.example.piliplus.localmedia

import org.videolan.libvlc.MediaPlayer

/**
 * Reflection shims for the PiliPlus VR extension of libvlc.
 *
 * The app may be built against either the patched AAR (libs/libvlc-pvr.aar,
 * carries setVrMode/getVrVersion) or the stock Maven artifact (which does
 * not). Reflection keeps a single code path compiling against both, and the
 * runtime probe drives the "engine lacks VR support" UI notice.
 */
object VlcCompat {
    private fun method(mp: MediaPlayer, name: String, vararg types: Class<*>) =
        try {
            mp.javaClass.getMethod(name, *types)
        } catch (t: Throwable) {
            null
        }

    /** 0 when the engine has no VR extension. */
    fun getVrVersion(mp: MediaPlayer): Int {
        val m = method(mp, "getVrVersion") ?: return 0
        return try {
            (m.invoke(mp) as? Int) ?: 0
        } catch (t: Throwable) {
            0
        }
    }

    fun setVrMode(mp: MediaPlayer, projection: Int, stereo: Int, eye: Int): Boolean {
        val m = method(
            mp, "setVrMode",
            Int::class.javaPrimitiveType!!,
            Int::class.javaPrimitiveType!!,
            Int::class.javaPrimitiveType!!
        ) ?: return false
        return try {
            (m.invoke(mp, projection, stereo, eye) as? Boolean) ?: false
        } catch (t: Throwable) {
            LogCollector.e("VlcCompat", "setVrMode failed", t)
            false
        }
    }
}
