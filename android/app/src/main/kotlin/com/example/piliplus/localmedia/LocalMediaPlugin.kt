package com.example.piliplus.localmedia

import android.content.Context
import android.database.ContentObserver
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.videolan.libvlc.Dialog
import java.util.concurrent.Executors

/**
 * Bridge between Dart and the local-media native services (libvlc player,
 * MediaStore scanner, network browser/downloader, diagnostics).
 *
 * Everything here is local/LAN only: no B-site code path is touched, which
 * keeps the offline guarantee (no site requests during local playback).
 */
object LocalMediaPlugin : MethodChannel.MethodCallHandler {

    private const val CHANNEL = "piliplus/local"
    private const val EVENT_CHANNEL = "piliplus/local_events"
    private const val TAG = "LocalMediaPlugin"

    private lateinit var appContext: Context
    private var methodChannel: MethodChannel? = null
    private var eventSink: EventChannel.EventSink? = null
    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor()

    private var player: PlayerBridge? = null
    private var scanner: MediaScanner? = null
    private var netBrowser: NetBrowser? = null
    private var downloader: NetDownloader? = null
    private var observer: ContentObserver? = null
    private var lastAutoDelta = 0L

    @Volatile
    private var scanning = false

    fun attach(
        context: Context,
        messenger: io.flutter.plugin.common.BinaryMessenger
    ) {
        appContext = context.applicationContext
        // Start diagnostics FIRST: file-backed log + logcat capture + uncaught
        // handler, so even a hard failure during engine init leaves a trail
        // that survives the process death.
        try {
            LogCollector.attach(appContext)
            LogCollector.i(
                TAG,
                "attach: ${Build.MANUFACTURER} ${Build.MODEL} android=${Build.VERSION.RELEASE} sdk=${Build.VERSION.SDK_INT} abis=${Build.SUPPORTED_ABIS.joinToString()}"
            )
        } catch (t: Throwable) {
            android.util.Log.e(TAG, "LogCollector attach failed", t)
        }
        val channel = MethodChannel(messenger, CHANNEL)
        channel.setMethodCallHandler(this)
        methodChannel = channel

        val events = EventChannel(messenger, EVENT_CHANNEL)
        events.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
                eventSink = sink
                wireEmitters()
            }

            override fun onCancel(arguments: Any?) {
                eventSink = null
            }
        })

        LogCollector.i(TAG, "bridge attached")
    }

    private fun emit(map: Map<String, Any?>) {
        main.post { eventSink?.success(map) }
    }

    private fun wireEmitters() {
        player?.eventSink = ::emit
        netBrowser?.setEmitter(::emit)
        downloader?.setEmitter(::emit)
    }

    /** Called from VideoViews.dispose so the player detaches its surfaces. */
    fun onVideoViewDisposed(viewId: Int) {
        main.post {
            try {
                player?.detach()
            } catch (t: Throwable) {
                LogCollector.e(TAG, "detach on dispose failed", t)
            }
        }
    }

    // ---- method handling ----------------------------------------------------

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                // ---------- engine ----------
                "engineInit" -> io.execute {
                    try {
                        VlcEngine.ensureInit(appContext)
                        LogCollector.startLogcatCapture()
                        main.post {
                            result.success(
                                mapOf(
                                    "vrVersion" to VlcEngine.vrVersion(),
                                    "version" to runCatching { org.videolan.libvlc.LibVLC.version() }.getOrDefault(""),
                                )
                            )
                        }
                    } catch (t: Throwable) {
                        main.post { result.error("ENGINE_INIT", t.toString(), null) }
                    }
                }

                "engineInfo" -> {
                    val vlc = VlcEngine.libVlc
                    result.success(
                        mapOf(
                            "initialized" to (vlc != null),
                            "vrVersion" to if (vlc != null) VlcEngine.vrVersion() else 0,
                            "version" to runCatching { org.videolan.libvlc.LibVLC.version() }.getOrDefault(""),
                            "initError" to VlcEngine.lastInitError,
                        )
                    )
                }

                "engineRelease" -> {
                    io.execute {
                        try {
                            player?.release()
                            player = null
                            netBrowser?.release()
                            netBrowser = null
                            downloader?.release()
                            downloader = null
                            VlcEngine.release()
                            main.post { result.success(true) }
                        } catch (t: Throwable) {
                            LogCollector.e(TAG, "engineRelease failed", t)
                            main.post { result.success(false) }
                        }
                    }
                }

                // ---------- player ----------
                "playerCreate" -> {
                    if (player == null) {
                        player = PlayerBridge(appContext).also { it.eventSink = ::emit }
                    }
                    result.success(true)
                }

                "playerAttach" -> {
                    val viewId = call.argument<Int>("viewId")
                    val layout = viewId?.let { VideoViews.get(it) }
                    if (layout == null) {
                        result.error("NO_VIEW", "video view $viewId not found", null)
                        return
                    }
                    val p = requirePlayer(result) ?: return
                    p.attach(layout)
                    result.success(true)
                }

                "playerOpen" -> {
                    val p = requirePlayer(result) ?: return
                    val uris = call.argument<List<String>>("uris") ?: emptyList()
                    val index = call.argument<Int>("index") ?: 0
                    val startMs = (call.argument<Number>("startMs") ?: 0).toLong()
                    val rate = call.argument<Double>("rate") ?: 1.0
                    val glVout = call.argument<Boolean>("glVout") ?: false
                    val caching = call.argument<Int>("networkCachingMs") ?: 2000
                    io.execute {
                        p.open(uris, index, startMs, rate, glVout, caching)
                        main.post { result.success(true) }
                    }
                }

                "playerReopen" -> {
                    val p = requirePlayer(result) ?: return
                    val glVout = call.argument<Boolean>("glVout") ?: false
                    val caching = call.argument<Int>("networkCachingMs") ?: 2000
                    io.execute {
                        p.reopen(glVout, caching, true)
                        main.post { result.success(true) }
                    }
                }

                "playerPlay" -> { player?.play(); result.success(true) }
                "playerPause" -> { player?.pause(); result.success(true) }
                "playerStop" -> { io.execute { player?.stop() }; result.success(true) }

                "playerRelease" -> {
                    io.execute {
                        try { player?.release() } catch (t: Throwable) { LogCollector.e(TAG, "playerRelease", t) }
                        player = null
                    }
                    result.success(true)
                }

                "playerSeek" -> {
                    val p = requirePlayer(result) ?: return
                    p.seek((call.argument<Number>("ms") ?: 0).toLong(), call.argument<Boolean>("fast") ?: false)
                    result.success(true)
                }

                "playerSetRate" -> {
                    player?.setRate(call.argument<Double>("rate") ?: 1.0)
                    result.success(true)
                }

                "playerTime" -> result.success(player?.time() ?: 0L)

                "playerIsPlaying" -> result.success(player?.isPlaying() ?: false)

                "playerTracks" -> {
                    val p = requirePlayer(result) ?: return
                    result.success(p.tracks(call.argument<String>("type") ?: "spu"))
                }

                "playerSelectedTrack" -> {
                    val p = requirePlayer(result) ?: return
                    result.success(p.selectedTrack(call.argument<String>("type") ?: "spu"))
                }

                "playerSelectTrack" -> {
                    val p = requirePlayer(result) ?: return
                    result.success(
                        p.selectTrack(
                            call.argument<String>("type") ?: "spu",
                            call.argument<Int>("id") ?: -1
                        )
                    )
                }

                "playerAddSubtitle" -> {
                    val p = requirePlayer(result) ?: return
                    result.success(p.addSubtitle(call.argument<String>("uri") ?: ""))
                }

                // ---------- VR ----------
                "playerVrVersion" -> result.success(player?.vrVersion() ?: 0)

                "playerSetVrMode" -> {
                    val p = requirePlayer(result) ?: return
                    result.success(
                        p.setVrMode(
                            call.argument<Int>("projection") ?: 0,
                            call.argument<Int>("stereo") ?: 0,
                            call.argument<Int>("eye") ?: 0
                        )
                    )
                }

                "playerUpdateViewpoint" -> {
                    val p = requirePlayer(result) ?: return
                    result.success(
                        p.updateViewpoint(
                            (call.argument<Number>("yaw") ?: 0).toFloat(),
                            (call.argument<Number>("pitch") ?: 0).toFloat(),
                            (call.argument<Number>("fov") ?: 80).toFloat(),
                            call.argument<Boolean>("absolute") ?: true
                        )
                    )
                }

                "playerSetGyro" -> {
                    player?.setGyro(call.argument<Boolean>("enabled") ?: false)
                    result.success(true)
                }

                "playerResetViewpoint" -> { player?.resetViewpoint(); result.success(true) }

                "playerSetFov" -> {
                    player?.setFov((call.argument<Number>("fov") ?: 80).toFloat())
                    result.success(true)
                }

                "playerViewpoint" -> result.success(player?.currentViewpoint() ?: emptyMap<String, Any>())

                // ---------- aspect / snapshot ----------
                "playerSetAspect" -> {
                    player?.setAspectRatio(call.argument<String>("aspect"))
                    result.success(true)
                }

                "playerSnapshot" -> {
                    val p = requirePlayer(result) ?: return
                    val path = call.argument<String>("path") ?: ""
                    p.takeSnapshot(path) { ok -> main.post { result.success(ok) } }
                }

                // ---------- library ----------
                "libraryScan" -> {
                    val s = scanner ?: MediaScanner(appContext).also { scanner = it }
                    if (scanning) {
                        result.success(false)
                        return
                    }
                    scanning = true
                    io.execute {
                        s.fullScan(
                            onBatch = { batch, count ->
                                emit(mapOf("type" to "scanBatch", "videos" to batch, "count" to count))
                            },
                            onProgress = { count -> emit(mapOf("type" to "scanProgress", "count" to count)) },
                            onDone = { count ->
                                scanning = false
                                emit(mapOf("type" to "scanDone", "count" to count))
                                registerObserver(s)
                            },
                            onError = { msg ->
                                scanning = false
                                emit(mapOf("type" to "scanError", "message" to msg))
                            }
                        )
                    }
                    result.success(true)
                }

                "libraryDelta" -> {
                    val s = scanner ?: MediaScanner(appContext).also { scanner = it }
                    io.execute { runDelta(s) }
                    result.success(true)
                }

                "librarySearch" -> io.execute {
                    val s = scanner ?: MediaScanner(appContext).also { scanner = it }
                    val out = s.search(
                        call.argument<String>("query") ?: "",
                        (call.argument<Number>("bucketId"))?.toLong(),
                        call.argument<Int>("limit") ?: 300
                    )
                    main.post { result.success(out) }
                }

                // ---------- network ----------
                "netDiscover" -> {
                    val nb = netBrowser ?: NetBrowser(appContext).also {
                        netBrowser = it
                        it.setEmitter(::emit)
                    }
                    io.execute { nb.startDiscovery(call.argument<String>("service")) }
                    result.success(true)
                }

                "netStopDiscovery" -> { netBrowser?.stopDiscovery(); result.success(true) }

                "netBrowse" -> {
                    val nb = netBrowser ?: NetBrowser(appContext).also {
                        netBrowser = it
                        it.setEmitter(::emit)
                    }
                    io.execute { nb.browse(call.argument<String>("url") ?: "") }
                    result.success(true)
                }

                "netDownload" -> {
                    val d = downloader ?: NetDownloader(appContext).also {
                        downloader = it
                        it.setEmitter(::emit)
                    }
                    val id = d.start(
                        call.argument<String>("url") ?: "",
                        call.argument<String>("destDir") ?: "",
                        call.argument<String>("fileName") ?: "download.bin"
                    )
                    result.success(id)
                }

                "netDownloadCancel" -> {
                    downloader?.cancel(call.argument<Int>("id") ?: -1)
                    result.success(true)
                }

                // ---------- dialogs (credentials etc.) ----------
                "dialogPostLogin" -> {
                    val id = call.argument<Int>("id") ?: -1
                    val dialog = VlcEngine.dialogById(id) as? Dialog.LoginDialog
                    if (dialog != null) {
                        dialog.postLogin(
                            call.argument<String>("username") ?: "",
                            call.argument<String>("password") ?: "",
                            call.argument<Boolean>("store") ?: false
                        )
                    }
                    VlcEngine.removeDialog(id)
                    result.success(true)
                }

                "dialogPostAction" -> {
                    val id = call.argument<Int>("id") ?: -1
                    val dialog = VlcEngine.dialogById(id) as? Dialog.QuestionDialog
                    dialog?.postAction(call.argument<Int>("action") ?: 0)
                    VlcEngine.removeDialog(id)
                    result.success(true)
                }

                "dialogDismiss" -> {
                    val id = call.argument<Int>("id") ?: -1
                    VlcEngine.dialogById(id)?.dismiss()
                    VlcEngine.removeDialog(id)
                    result.success(true)
                }

                // ---------- diagnostics ----------
                "logStart" -> { LogCollector.startLogcatCapture(); result.success(true) }
                "logStop" -> { LogCollector.stopLogcatCapture(); result.success(true) }
                "logGet" -> result.success(LogCollector.snapshot())
                "logClear" -> { LogCollector.clear(); result.success(true) }

                "logAdd" -> {
                    LogCollector.add(
                        call.argument<String>("level") ?: "I",
                        call.argument<String>("tag") ?: "dart",
                        call.argument<String>("msg") ?: ""
                    )
                    result.success(true)
                }

                "deviceInfo" -> result.success(deviceInfo())

                else -> result.notImplemented()
            }
        } catch (t: Throwable) {
            LogCollector.e(TAG, "method ${call.method} failed", t)
            result.error("BRIDGE_ERROR", t.toString(), null)
        }
    }

    private fun requirePlayer(result: MethodChannel.Result): PlayerBridge? {
        val p = player ?: PlayerBridge(appContext).also {
            player = it
            it.eventSink = ::emit
        }
        return p
    }

    private fun deviceInfo(): Map<String, Any?> {
        val pm = appContext.packageManager
        val pkg = appContext.packageName
        val versionInfo = runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                pm.getPackageInfo(pkg, android.content.pm.PackageManager.PackageInfoFlags.of(0L))
            } else {
                @Suppress("DEPRECATION")
                pm.getPackageInfo(pkg, 0)
            }
        }.getOrNull()
        return mapOf(
            "model" to "${Build.MANUFACTURER} ${Build.MODEL}",
            "device" to Build.DEVICE,
            "androidVersion" to Build.VERSION.RELEASE,
            "sdkInt" to Build.VERSION.SDK_INT,
            "abis" to Build.SUPPORTED_ABIS.toList(),
            "appVersion" to (versionInfo?.versionName ?: ""),
            "appVersionCode" to if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                versionInfo?.longVersionCode ?: 0L
            } else {
                @Suppress("DEPRECATION")
                (versionInfo?.versionCode?.toLong() ?: 0L)
            },
            "totalMemMb" to (runCatching {
                val am = appContext.getSystemService(Context.ACTIVITY_SERVICE) as android.app.ActivityManager
                val mi = android.app.ActivityManager.MemoryInfo()
                am.getMemoryInfo(mi)
                mi.totalMem / 1048576L
            }.getOrDefault(0L)),
        )
    }

    // ---- library auto refresh ------------------------------------------------

    private fun runDelta(s: MediaScanner) {
        s.deltaScan(
            onAdded = { added -> emit(mapOf("type" to "scanBatch", "videos" to added, "count" to added.size, "delta" to true)) },
            onRemoved = { removed -> emit(mapOf("type" to "scanRemoved", "ids" to removed)) },
            onError = { msg -> if (msg != "no_base_scan") emit(mapOf("type" to "scanError", "message" to msg)) }
        )
    }

    private fun registerObserver(s: MediaScanner) {
        if (observer != null) return
        val o = object : ContentObserver(main) {
            override fun onChange(selfChange: Boolean, uri: Uri?) {
                val now = System.currentTimeMillis()
                if (now - lastAutoDelta < 5000) return
                lastAutoDelta = now
                io.execute { runDelta(s) }
            }
        }
        observer = o
        runCatching {
            appContext.contentResolver.registerContentObserver(
                MediaStore.Video.Media.EXTERNAL_CONTENT_URI, true, o
            )
        }.onFailure { LogCollector.w(TAG, "observer registration failed: $it") }
    }

    init {
        VlcEngine.dialogListener = object : VlcEngine.DialogListener {
            override fun onLogin(dialog: Dialog.LoginDialog, id: Int) {
                emit(
                    mapOf(
                        "type" to "loginDialog",
                        "id" to id,
                        "title" to (dialog.title ?: ""),
                        "text" to (dialog.text ?: ""),
                        "username" to (dialog.defaultUsername ?: ""),
                        "askStore" to dialog.asksStore()
                    )
                )
            }

            override fun onError(title: String, text: String) {
                LogCollector.e("VlcDialog", "$title: $text")
                emit(mapOf("type" to "vlcErrorDialog", "title" to title, "text" to text))
            }

            override fun onProgress(dialog: Dialog.ProgressDialog, id: Int) {
                // Progress dialogs (e.g. write errors) are surfaced as plain events.
                emit(
                    mapOf(
                        "type" to "vlcProgressDialog",
                        "id" to id,
                        "title" to (dialog.title ?: ""),
                        "text" to (dialog.text ?: ""),
                        "cancelable" to dialog.isCancelable
                    )
                )
            }
        }
    }
}
