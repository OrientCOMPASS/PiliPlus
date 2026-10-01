import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/services/local_media/local_library_service.dart';
import 'package:PiliPlus/services/local_media/local_media_channel.dart';
import 'package:PiliPlus/services/local_media/log_ring.dart';
import 'package:PiliPlus/services/local_media/models.dart';
import 'package:PiliPlus/utils/image_utils.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/vr_filename.dart';
import 'package:flutter/services.dart';
import 'package:flutter_volume_controller/flutter_volume_controller.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:screen_brightness_platform_interface/screen_brightness_platform_interface.dart';

enum LocalPlayStatus { idle, opening, playing, paused, ended, error }

/// Controller for the unified local/LAN player page (libvlc engine).
///
/// Offline guarantee: nothing in this controller (or the native bridge it
/// drives) issues any bilibili request; resume/history records go to the
/// local hive box only.
class LocalPlayerController extends GetxController {
  LocalPlayerController({
    required this.uris,
    required this.titles,
    required this.initialIndex,
    required this.isNetwork,
    this.paths = const [],
    this.playlistName = '',
  });

  /// Playable URIs (content:// for local library, smb://… for LAN).
  final List<String> uris;
  final List<String> titles;

  /// Real filesystem paths when known (local library items) — used for
  /// same-name subtitle auto detection.
  final List<String> paths;
  final int initialIndex;
  final bool isNetwork;
  final String playlistName;

  final LocalMediaChannel _ch = LocalMediaChannel.instance;

  // ---- state ----
  final Rx<LocalPlayStatus> status = LocalPlayStatus.idle.obs;
  final RxString errorMessage = ''.obs;
  final RxInt index = 0.obs;
  final RxInt positionMs = 0.obs;
  final RxInt durationMs = 0.obs;
  final RxDouble buffering = 0.0.obs;
  final RxBool playing = false.obs;
  final RxDouble rate = 1.0.obs;
  final RxBool showControls = true.obs;
  final RxBool rotationLocked = false.obs;
  final RxBool engineReady = false.obs;
  final RxInt vrEngineVersion = 0.obs;

  // tracks
  final RxList<Map> audioTracks = <Map>[].obs;
  final RxList<Map> spuTracks = <Map>[].obs;
  final RxInt selAudio = (-1).obs;
  final RxInt selSpu = (-1).obs;
  final RxString spuLabel = ''.obs;

  // VR
  final Rx<VrProjection> vrProjection = VrProjection.auto.obs;
  final Rx<VrStereo> vrStereo = VrStereo.auto.obs;
  final Rx<VrEye> vrEye = VrEye.left.obs;
  final RxBool vrActive = false.obs; // current rendering uses spherical mode
  final RxBool vrUnsupported = false.obs;
  final RxBool gyroEnabled = false.obs;
  final RxBool gyroAvailable = true.obs;
  final RxDouble vpYaw = 0.0.obs;
  final RxDouble vpPitch = 0.0.obs;
  final RxDouble vpFov = 80.0.obs;

  // aspect
  static const List<String?> _aspects = [null, '16:9', '4:3', '1:1', '2.35:1'];
  static const List<String> _aspectLabels = ['自动', '16:9', '4:3', '1:1', '2.35:1'];
  final RxInt aspectIndex = 0.obs;

  // sleep timer
  final RxInt sleepMinutes = 0.obs;
  Timer? _sleepTimer;

  StreamSubscription<Map>? _sub;
  Timer? _resumeTimer;
  Timer? _hideTimer;
  bool _attached = false;
  bool _subtitleAutoDetectDone = false;
  bool _useGlVout = false;

  String get currentUri => uris[index.value];
  String get currentTitle =>
      index.value < titles.length ? titles[index.value] : currentUri;

  double get brightness => _brightness;
  double _brightness = 0.5;
  double get volume => _volume;
  double _volume = 0.5;

  // ---- lifecycle ----

  @override
  void onInit() {
    super.onInit();
    if (!Get.isRegistered<LocalLibraryService>()) {
      Get.put(LocalLibraryService());
    }
    index.value = initialIndex;
    _sub = _ch.events.listen(_onEvent);
    _initEngine();
  }

  Future<void> _initEngine() async {
    try {
      final info = await _ch.engineInit();
      vrEngineVersion.value = (info['vrVersion'] as num?)?.toInt() ?? 0;
      engineReady.value = true;
      vrUnsupported.value = vrEngineVersion.value == 0;
      await _openCurrent(resume: true);
    } catch (e, st) {
      status.value = LocalPlayStatus.error;
      errorMessage.value = '播放引擎初始化失败：$e';
      LocalLogRing.instance.e('LocalPlayer', 'engine init failed', st);
    }
  }

  @override
  void onClose() {
    _persistResume();
    _resumeTimer?.cancel();
    _hideTimer?.cancel();
    _sleepTimer?.cancel();
    _sub?.cancel();
    _ch.playerStop();
    _ch.playerRelease();
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    ScreenBrightnessPlatform.instance.resetApplicationScreenBrightness();
    FlutterVolumeController.updateShowSystemUI(true);
    super.onClose();
  }

  /// Called by the view when the platform view is created.
  Future<void> attachView(int viewId) async {
    if (_attached) return;
    try {
      await _ch.playerAttach(viewId);
      _attached = true;
      if (engineReady.value && status.value == LocalPlayStatus.idle) {
        await _openCurrent(resume: true);
      } else if (engineReady.value && _pendingOpen) {
        _pendingOpen = false;
        await _openCurrent(resume: true);
      }
    } catch (e, st) {
      LocalLogRing.instance.e('LocalPlayer', 'attachView failed', st);
    }
  }

  bool _pendingOpen = false;

  // ---- open / play ----

  Future<void> _openCurrent({bool resume = false}) async {
    if (!_attached) {
      _pendingOpen = true;
      return;
    }
    status.value = LocalPlayStatus.opening;
    errorMessage.value = '';
    buffering.value = 0;

    final uri = currentUri;
    // Per-source VR override (user choice) wins over filename detection.
    final override = LocalLibraryService.to.vrOverrideFor(uri);
    VrDetectResult detect = VrDetectResult.none;
    if (Pref.localVrAutoDetect) {
      detect = VrFilename.detect(path.basename(titles.isNotEmpty && index.value < titles.length ? titles[index.value] : uri));
    }
    if (override != null) {
      vrProjection.value = VrProjection.fromValue((override['proj'] as num?)?.toInt() ?? 0);
      vrStereo.value = VrStereo.fromValue((override['stereo'] as num?)?.toInt() ?? 0);
      vrEye.value = (override['eye'] as num?)?.toInt() == 1 ? VrEye.right : VrEye.left;
    } else {
      vrProjection.value = detect.projection;
      vrStereo.value = detect.stereo;
    }
    _useGlVout = detect.vrHint ||
        override != null ||
        vrProjection.value == VrProjection.e360 ||
        vrProjection.value == VrProjection.e180 ||
        vrStereo.value == VrStereo.sbs ||
        vrStereo.value == VrStereo.tb;

    int startMs = 0;
    if (resume) {
      final record = LocalLibraryService.to.recordFor(uri);
      if (record != null && !record.finished) {
        startMs = record.positionMs;
      }
      LocalLibraryService.to.countPlay(uri);
    }
    _subtitleAutoDetectDone = false;

    try {
      await _ch.playerOpen(
        uris: uris,
        index: index.value,
        startMs: startMs,
        rate: rate.value,
        glVout: _useGlVout,
      );
      // Apply VR mode up-front so the first frame is already correct.
      await _applyVrMode();
      if (Pref.localGyroDefault && _wantsSpherical() && gyroAvailable.value) {
        await toggleGyro(true);
      }
      // 点开即播：本地板块没有“先不播”的语义。
      await _ch.playerPlay();
      _startResumeTimer();
    } catch (e, st) {
      status.value = LocalPlayStatus.error;
      errorMessage.value = '打开失败：$e';
      LocalLogRing.instance.e('LocalPlayer', 'open failed: $uri', st);
    }
  }

  Future<void> _applyVrMode() async {
    final ok = await _ch.playerSetVrMode(
      projection: vrProjection.value.value,
      stereo: vrStereo.value.value,
      eye: vrEye.value.value,
    );
    if (!ok && _wantsSpherical()) {
      vrUnsupported.value = true;
      LocalLogRing.instance.w(
        'LocalPlayer',
        'engine rejected VR mode (proj=${vrProjection.value} stereo=${vrStereo.value})',
      );
    }
    _updateVrActive();
  }

  bool _wantsSpherical() =>
      vrProjection.value == VrProjection.e360 ||
      vrProjection.value == VrProjection.e180;

  void _updateVrActive() {
    vrActive.value = _wantsSpherical() ||
        vrProjection.value == VrProjection.auto && _useGlVout;
  }

  // ---- events ----

  void _onEvent(Map event) {
    switch (event['type'] as String? ?? '') {
      case 'player':
        _onPlayerEvent(event['event'] as String? ?? '', (event['value'] as num?)?.toDouble());
      case 'time':
        positionMs.value = (event['ms'] as num?)?.toInt() ?? 0;
        final len = (event['lengthMs'] as num?)?.toInt() ?? 0;
        if (len > 0) durationMs.value = len;
      case 'tracks':
        audioTracks.assignAll((event['audio'] as List? ?? const []).cast<Map>());
        spuTracks.assignAll((event['spu'] as List? ?? const []).cast<Map>());
        selAudio.value = (event['selAudio'] as num?)?.toInt() ?? -1;
        selSpu.value = (event['selSpu'] as num?)?.toInt() ?? -1;
        _updateSpuLabel();
      case 'vrHud':
        vpYaw.value = (event['yaw'] as num?)?.toDouble() ?? 0;
        vpPitch.value = (event['pitch'] as num?)?.toDouble() ?? 0;
        if ((event['fov'] as num?) != null) {
          vpFov.value = (event['fov'] as num).toDouble();
        }
      case 'gyroUnavailable':
        gyroAvailable.value = false;
        gyroEnabled.value = false;
      case 'vlcErrorDialog':
        LocalLogRing.instance.w(
          'LocalPlayer',
          'vlc dialog: ${event['title']} ${event['text']}',
        );
      case 'loginDialog':
        onLoginDialog(event);
      case 'focusLost':
        playing.value = false;
    }
  }

  void _onPlayerEvent(String name, double? value) {
    switch (name) {
      case 'opening':
        status.value = LocalPlayStatus.opening;
      case 'playing':
        status.value = LocalPlayStatus.playing;
        playing.value = true;
        errorMessage.value = '';
        _autoDetectSubtitles();
      case 'paused':
        playing.value = false;
        if (status.value != LocalPlayStatus.error) {
          status.value = LocalPlayStatus.paused;
        }
        _persistResume();
      case 'stopped':
        playing.value = false;
      case 'end':
        _persistResume(force: true);
        _onEndReached();
      case 'error':
        status.value = LocalPlayStatus.error;
        playing.value = false;
        errorMessage.value =
            '播放失败：${isNetwork ? '网络源' : '本地文件'} ${Uri.tryParse(currentUri)?.pathSegments.last ?? currentTitle}';
        LocalLogRing.instance.e('LocalPlayer', errorMessage.value);
      case 'buffering':
        buffering.value = value ?? 0;
      case 'vout':
        break;
    }
  }

  void _onEndReached() {
    // 看到结尾视为看完：清除续播记录。
    LocalLibraryService.to.clearRecord(currentUri);
    positionMs.value = durationMs.value;
    if (uris.length > 1) {
      playNext(auto: true);
    } else {
      status.value = LocalPlayStatus.ended;
      playing.value = false;
    }
  }

  // ---- controls ----

  void togglePlay() {
    if (playing.value) {
      _ch.playerPause();
    } else {
      if (status.value == LocalPlayStatus.error) {
        retry();
        return;
      }
      _ch.playerPlay();
    }
    bumpControls();
  }

  Future<void> retry() async {
    status.value = LocalPlayStatus.opening;
    await _openCurrent(resume: true);
  }

  void seekTo(int ms, {bool fast = false}) {
    final target = ms.clamp(0, durationMs.value == 0 ? ms : durationMs.value);
    positionMs.value = target;
    _ch.playerSeek(target, fast: fast);
    bumpControls();
  }

  void seekBy(int deltaMs) => seekTo(positionMs.value + deltaMs);

  void setRate(double v) {
    rate.value = v;
    _ch.playerSetRate(v);
  }

  void playIndex(int i, {bool resume = true}) {
    if (i < 0 || i >= uris.length || i == index.value && status.value == LocalPlayStatus.playing) {
      return;
    }
    _persistResume();
    index.value = i;
    _openCurrent(resume: resume);
  }

  void playNext({bool auto = false}) {
    if (uris.length <= 1) return;
    final next = (index.value + 1) % uris.length;
    if (auto && next == 0) {
      // 列表循环：回到开头继续
    }
    playIndex(next, resume: !auto);
  }

  void playPrev() {
    if (uris.length <= 1) return;
    final prev = (index.value - 1 + uris.length) % uris.length;
    playIndex(prev, resume: false);
  }

  // ---- tracks / subtitles ----

  Future<void> refreshTracks() async {
    audioTracks.assignAll(await _ch.playerTracks('audio'));
    spuTracks.assignAll(await _ch.playerTracks('spu'));
    selAudio.value = await _ch.playerSelectedTrack('audio');
    selSpu.value = await _ch.playerSelectedTrack('spu');
    _updateSpuLabel();
  }

  Future<void> selectAudioTrack(int id) async {
    if (await _ch.playerSelectTrack('audio', id)) selAudio.value = id;
  }

  Future<void> selectSpuTrack(int id) async {
    if (await _ch.playerSelectTrack('spu', id)) {
      selSpu.value = id;
      _updateSpuLabel();
    }
  }

  void _updateSpuLabel() {
    if (selSpu.value == -1) {
      spuLabel.value = spuTracks.isEmpty ? '无' : '关闭';
      return;
    }
    final match = spuTracks.where((t) => (t['id'] as num?)?.toInt() == selSpu.value);
    var name = match.isEmpty ? '字幕' : (match.first['name'] as String? ?? '字幕');
    if (name.isEmpty) name = '字幕';
    // 短标签：轨道名往往冗长，取前几个可读字符。
    spuLabel.value = name.length > 6 ? '${name.substring(0, 6)}…' : name;
  }

  /// Best-effort same-name external subtitle detection for local files.
  /// Direct path access works where the OS allows it (legacy storage or
  /// files visible to the app); otherwise the user can pick manually.
  void _autoDetectSubtitles() {
    if (_subtitleAutoDetectDone || isNetwork) return;
    _subtitleAutoDetectDone = true;
    String? filePath =
        index.value < paths.length && paths[index.value].isNotEmpty
        ? paths[index.value]
        : _localPathOf(currentUri);
    if (filePath == null || !filePath.contains('.')) return;
    Future(() {
      const exts = ['.srt', '.ass', '.ssa', '.vtt', '.sub', '.idx'];
      final base = filePath.substring(0, filePath.lastIndexOf('.'));
      for (final ext in exts) {
        try {
          final f = File('$base$ext');
          if (f.existsSync()) {
            _ch.playerAddSubtitle(Uri.file(f.path).toString());
            LocalLogRing.instance.i('LocalPlayer', 'auto subtitle: ${f.path}');
            return;
          }
        } catch (_) {}
      }
    });
  }

  String? _localPathOf(String uri) {
    String p;
    if (uri.startsWith('file://')) {
      p = Uri.parse(uri).toFilePath();
    } else if (uri.startsWith('/')) {
      p = uri;
    } else {
      return null;
    }
    if (!p.contains('.')) return null;
    return p;
  }

  Future<void> addSubtitleFile(String filePathOrUri) async {
    final uri = filePathOrUri.startsWith('/')
        ? Uri.file(filePathOrUri).toString()
        : filePathOrUri;
    final ok = await _ch.playerAddSubtitle(uri);
    if (!ok) {
      LocalLogRing.instance.w('LocalPlayer', 'addSubtitle failed: $uri');
    }
  }

  // ---- VR ----

  Future<void> setVrProjection(VrProjection p) async {
    final prev = vrProjection.value;
    vrProjection.value = p;
    // 先把新模式写入引擎（media player 变量），再视需要切换 vout，
    // 保证重开时首帧即为新投影（原位续进度）。
    final ok = await _applyVrModeSafe();
    if (!ok && vrEngineVersion.value == 0) {
      vrProjection.value = prev;
      return;
    }
    final needGl = p == VrProjection.e360 || p == VrProjection.e180;
    if (needGl && !_useGlVout) {
      // flat source rendered through android_display: switch vout in place
      // (reopen keeps position).
      _useGlVout = true;
      await _ch.playerReopen(glVout: true);
      await _applyVrModeSafe();
    }
    LocalLibraryService.to.saveVrOverride(
      currentUri,
      vrProjection.value.value,
      vrStereo.value.value,
      vrEye.value.value,
    );
  }

  Future<void> setVrStereo(VrStereo s) async {
    vrStereo.value = s;
    await _applyVrModeSafe();
    LocalLibraryService.to.saveVrOverride(
      currentUri,
      vrProjection.value.value,
      vrStereo.value.value,
      vrEye.value.value,
    );
  }

  Future<void> toggleEye() async {
    vrEye.value = vrEye.value == VrEye.left ? VrEye.right : VrEye.left;
    await _applyVrModeSafe();
    LocalLibraryService.to.saveVrOverride(
      currentUri,
      vrProjection.value.value,
      vrStereo.value.value,
      vrEye.value.value,
    );
  }

  Future<bool> _applyVrModeSafe() async {
    final ok = await _ch.playerSetVrMode(
      projection: vrProjection.value.value,
      stereo: vrStereo.value.value,
      eye: vrEye.value.value,
    );
    if (!ok && vrEngineVersion.value == 0) vrUnsupported.value = true;
    _updateVrActive();
    return ok;
  }

  Future<void> toggleGyro([bool? value]) async {
    final target = value ?? !gyroEnabled.value;
    gyroEnabled.value = target;
    await _ch.playerSetGyro(target);
  }

  Future<void> recenterViewpoint() => _ch.playerResetViewpoint();

  /// Manual look-around (non-gyro). Mirrors the engine's 180° clamping so
  /// the HUD matches what is rendered.
  void dragViewpoint(double dYawDeg, double dPitchDeg) {
    if (gyroEnabled.value) return;
    var yaw = vpYaw.value + dYawDeg;
    var pitch = vpPitch.value + dPitchDeg;
    if (vrProjection.value == VrProjection.e180) {
      final limYaw = (90 - vpFov.value / 2).clamp(0.0, 90.0);
      yaw = yaw.clamp(-limYaw, limYaw);
      final limPitch = (90 - vpFov.value / 2).clamp(0.0, 90.0);
      pitch = pitch.clamp(-limPitch, limPitch);
    } else {
      pitch = pitch.clamp(-89.0, 89.0);
      if (yaw > 180) yaw -= 360;
      if (yaw < -180) yaw += 360;
    }
    vpYaw.value = yaw;
    vpPitch.value = pitch;
    _ch.playerUpdateViewpoint(
      yaw: yaw,
      pitch: pitch,
      fov: vpFov.value,
      absolute: true,
    );
  }

  void setFov(double fov) {
    vpFov.value = fov.clamp(20.0, 140.0);
    _ch.playerSetFov(vpFov.value);
    if (vrProjection.value == VrProjection.e180) {
      // re-clamp yaw/pitch for the new fov
      dragViewpoint(0, 0);
    }
  }

  // ---- aspect / rotation / snapshot / sleep ----

  void cycleAspect() {
    aspectIndex.value = (aspectIndex.value + 1) % _aspects.length;
    _ch.playerSetAspect(_aspects[aspectIndex.value]);
  }

  String get aspectLabel => _aspectLabels[aspectIndex.value];

  void toggleRotationLock() {
    rotationLocked.value = !rotationLocked.value;
    if (rotationLocked.value) {
      final size = MediaQuery.sizeOf(Get.context!);
      final landscape = size.width > size.height;
      SystemChrome.setPreferredOrientations(
        landscape
            ? [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]
            : [DeviceOrientation.portraitUp],
      );
    } else {
      SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    }
  }

  Future<void> takeSnapshot() async {
    try {
      final dir = await getTemporaryDirectory();
      final file = File(
        path.join(dir.path, 'pili_snapshot_${DateTime.now().millisecondsSinceEpoch}.png'),
      );
      final ok = await _ch.playerSnapshot(file.path);
      if (!ok || !file.existsSync()) {
        LocalLogRing.instance.w('LocalPlayer', 'snapshot failed');
        return;
      }
      await ImageUtils.saveByteImg(
        bytes: await file.readAsBytes(),
        fileName: 'local_${DateTime.now().millisecondsSinceEpoch}',
      );
      runCatching(() => file.delete());
    } catch (e, st) {
      LocalLogRing.instance.e('LocalPlayer', 'snapshot failed', st);
    }
  }

  void setSleepTimer(int minutes) {
    sleepMinutes.value = minutes;
    _sleepTimer?.cancel();
    if (minutes <= 0) return;
    _sleepTimer = Timer(Duration(minutes: minutes), () {
      _ch.playerPause();
      sleepMinutes.value = 0;
    });
  }

  // ---- resume persistence ----

  void _startResumeTimer() {
    _resumeTimer?.cancel();
    _resumeTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (playing.value) _persistResume();
    });
  }

  void _persistResume({bool force = false}) {
    final pos = positionMs.value;
    final dur = durationMs.value;
    if (pos <= 0) return;
    if (!force && !playing.value && status.value != LocalPlayStatus.paused) return;
    LocalLibraryService.to.saveRecord(currentUri, pos, dur);
  }

  // ---- brightness / volume (mirror pl_player behavior) ----

  Future<void> initBrightnessVolume() async {
    try {
      _brightness = await ScreenBrightnessPlatform.instance.application;
    } catch (_) {
      try {
        _brightness = await ScreenBrightnessPlatform.instance.system;
      } catch (_) {}
    }
    try {
      _volume = await FlutterVolumeController.getVolume() ?? 0.5;
    } catch (_) {}
  }

  Future<void> setBrightness(double v) async {
    _brightness = v.clamp(0.0, 1.0);
    try {
      if (Pref.setSystemBrightness) {
        await ScreenBrightnessPlatform.instance.setSystemScreenBrightness(_brightness);
      } else {
        await ScreenBrightnessPlatform.instance.setApplicationScreenBrightness(_brightness);
      }
    } catch (_) {}
  }

  Future<void> setVolume(double v) async {
    _volume = v.clamp(0.0, 1.0);
    try {
      FlutterVolumeController.updateShowSystemUI(false);
      await FlutterVolumeController.setVolume(_volume);
    } catch (_) {}
  }

  // ---- controls auto hide ----

  void bumpControls() {
    showControls.value = true;
    _hideTimer?.cancel();
    if (playing.value) {
      _hideTimer = Timer(const Duration(seconds: 4), () {
        showControls.value = false;
      });
    }
  }

  // ---- network credential dialog ----

  void Function(Map event)? loginDialogHandler;

  void onLoginDialog(Map event) {
    loginDialogHandler?.call(event);
  }
}

void runCatching(void Function() f) {
  try {
    f();
  } catch (_) {}
}
