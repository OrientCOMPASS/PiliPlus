import 'dart:async';

import 'package:PiliPlus/models/local_media/vr_format.dart';
import 'package:PiliPlus/plugin/pl_player/utils/fullscreen.dart';
import 'package:PiliPlus/services/vlc/vlc_library.dart';
import 'package:PiliPlus/services/vlc/vlc_player.dart';
import 'package:PiliPlus/utils/duration_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/services.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_volume_controller/flutter_volume_controller.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:screen_brightness_platform_interface/screen_brightness_platform_interface.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// 播放列表条目(媒体库文件夹 / 浏览目录里的同级视频)
class VlcPlaylistEntry {
  const VlcPlaylistEntry({
    required this.uri,
    required this.title,
    this.mlId = -1,
    this.startMs = 0,
  });

  final String uri;
  final String title;

  /// libmedialibrary 条目 id(网络流为 -1, 不写续播)
  final int mlId;
  final int startMs;
}

/// VLC 播放页: 本地/局域网媒体统一从这里播放。
///
/// 画面 = libvlc 渲染到 SurfaceTexture → Flutter [Texture](与主播放器的
/// media_kit/mpv 相同的外部纹理合成方式), 控件照常叠加。
/// 360°/全景片源由 libvlc 原生投影渲染(VLC 同款), 页面自动切换成环视
/// 操作(拖拽视角 / 陀螺仪 / 视场角), 视角在 Kotlin 侧逐帧下发, 不经过
/// Dart 往返。
class VlcPlayerPage extends StatefulWidget {
  const VlcPlayerPage({
    super.key,
    required this.playlist,
    this.initialIndex = 0,
  });

  final List<VlcPlaylistEntry> playlist;
  final int initialIndex;

  @override
  State<VlcPlayerPage> createState() => _VlcPlayerPageState();
}

class _VlcPlayerPageState extends State<VlcPlayerPage> {
  late final VlcPlayerController _c = Get.put(VlcPlayerController());
  late int _index = widget.initialIndex.clamp(0, widget.playlist.length - 1);

  bool _showControls = true;
  Timer? _hideTimer;
  Timer? _positionSaver;

  // 亮度/音量手势
  double? _brightnessBase;
  double? _volumeBase;
  bool _horizontalGesture = false;
  bool _gestureDecided = false;

  // 横向拖动 seek 预览
  Duration? _seekPreview;
  double _seekStartMs = 0;
  double _dragOriginDx = 0;

  // 进入时系统栏若本来就隐藏着(从全屏播放页进来), 退出时不要放出来
  late final bool _restoreSystemBar = showSystemBar_;

  // 360 环视: 双指缩放基准
  double _fovBase = 80;

  // VR 格式(§18): null = 未手动指定, 跟随文件名自动识别/元数据
  VrFormat? _vrManual;
  bool _vrRightEye = false;

  VlcPlaylistEntry get _entry => widget.playlist[_index];

  /// 当前生效的 VR 格式: 手动指定 > 文件名自动识别(可关) > auto(元数据)
  VrFormat get _effectiveVr {
    if (_vrManual case final m?) {
      return m;
    }
    if (Pref.vrAutoDetect) {
      if (VrFormat.detectFromName(_entry.title) case final d?) {
        return d;
      }
    }
    return VrFormat.auto;
  }

  @override
  void initState() {
    super.initState();
    hideSystemBar();
    WakelockPlus.enable();
    _c.onEnded = _onEnded;
    _c.fetchEngineInfo(); // 探测是否 VR 补丁版引擎(菜单提示用), 不阻塞起播
    _open(Duration(milliseconds: _entry.startMs));
    // 每 5 秒把续播位置写进 libml(与 VLC 同一存储), 进程被杀也不丢
    _positionSaver = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _saveProgress(),
    );
    _scheduleHide();
  }

  @override
  void dispose() {
    _positionSaver?.cancel();
    _hideTimer?.cancel();
    _saveProgress();
    WakelockPlus.disable();
    if (_brightnessBase != null) {
      ScreenBrightnessPlatform.instance.resetApplicationScreenBrightness();
    }
    if (_restoreSystemBar) {
      showSystemBar();
    }
    Get.delete<VlcPlayerController>();
    super.dispose();
  }

  Future<void> _open(Duration start) async {
    await _c.open(
      _entry.uri,
      start: start,
      rate: _c.rate.value,
      vrFormat: _effectiveVr,
      vrRightEye: _vrRightEye,
    );
    VlcLibrary.instance.addHistory(_entry.uri, _entry.title);
    if (mounted) {
      setState(() {});
    }
  }

  void _saveProgress() {
    final entry = _entry;
    if (entry.mlId < 0) {
      return;
    }
    final pos = _c.position.value;
    final len = _c.length.value;
    if (pos <= Duration.zero) {
      return;
    }
    if (len > Duration.zero && len - pos < const Duration(seconds: 10)) {
      VlcLibrary.instance.clearProgress(entry.mlId);
    } else {
      VlcLibrary.instance.setProgress(entry.mlId, pos);
    }
  }

  void _onEnded() {
    _saveProgress();
    // 列表循环: 播完自动下一个, 末尾回到开头
    if (_index + 1 < widget.playlist.length) {
      _switchTo(_index + 1);
    } else if (widget.playlist.length > 1) {
      _switchTo(0);
    }
  }

  Future<void> _switchTo(int index) async {
    if (index < 0 || index >= widget.playlist.length || index == _index) {
      return;
    }
    _saveProgress();
    setState(() {
      _index = index;
      _seekPreview = null;
      // 换条目: VR 手动覆盖/眼位回到"按新文件名识别"
      _vrManual = null;
      _vrRightEye = false;
    });
    _c.position.value = Duration.zero;
    _c.length.value = Duration.zero;
    await _open(Duration(milliseconds: _entry.startMs));
  }

  void _toggleControls() {
    setState(() => _showControls = !_showControls);
    _scheduleHide();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    if (_showControls) {
      _hideTimer = Timer(const Duration(seconds: 4), () {
        if (mounted && !_c.buffering.value) {
          setState(() => _showControls = false);
        }
      });
    }
  }

  // ---------------------------------------------------------------- 手势

  void _onScaleStart(ScaleStartDetails d) {
    _gestureDecided = false;
    _horizontalGesture = false;
    _brightnessBase = null;
    _volumeBase = null;
    _dragOriginDx = d.localFocalPoint.dx;
    _seekStartMs = _c.position.value.inMilliseconds.toDouble();
    _fovBase = _c.vpFov.value;
  }

  Future<void> _onScaleUpdate(ScaleUpdateDetails d) async {
    final size = MediaQuery.sizeOf(context);
    if (_c.is360.value) {
      // 360: 双指=视场角, 单指=环视(头追在 native 侧叠加)
      if (d.pointerCount > 1) {
        if (d.scale > 0) {
          await _c.setFov((_fovBase / d.scale).clamp(20.0, 140.0).toDouble());
        }
        return;
      }
      await _c.lookBy(
        dyaw: -d.focalPointDelta.dx * 0.25,
        dpitch: d.focalPointDelta.dy * 0.25,
      );
      return;
    }
    if (!_gestureDecided &&
        (d.focalPointDelta.dx.abs() > 6 || d.focalPointDelta.dy.abs() > 6)) {
      _gestureDecided = true;
      _horizontalGesture =
          d.focalPointDelta.dx.abs() > d.focalPointDelta.dy.abs();
      if (!_horizontalGesture && d.localFocalPoint.dx < size.width / 2) {
        _brightnessBase =
            await ScreenBrightnessPlatform.instance.application;
      } else if (!_horizontalGesture) {
        _volumeBase = await FlutterVolumeController.getVolume() ?? 0.5;
      }
    }
    if (_horizontalGesture) {
      // 横向: seek 预览(整屏宽度 ≈ 90 秒)
      final lenMs = _c.length.value.inMilliseconds;
      if (lenMs > 0) {
        final target = (_seekStartMs +
                (d.focalPoint.dx - _dragOriginDx) / size.width * 90000)
            .clamp(0, lenMs.toDouble())
            .toDouble();
        if (_seekPreview?.inMilliseconds != target.round()) {
          setState(() => _seekPreview = Duration(milliseconds: target.round()));
        }
      }
    } else {
      final dy = -d.focalPointDelta.dy / size.height;
      if (_brightnessBase != null) {
        final v = (_brightnessBase! + dy).clamp(0.01, 1.0).toDouble();
        _brightnessBase = v;
        await ScreenBrightnessPlatform.instance
            .setApplicationScreenBrightness(v);
      } else if (_volumeBase != null) {
        final v = (_volumeBase! + dy).clamp(0.0, 1.0).toDouble();
        _volumeBase = v;
        await FlutterVolumeController.setVolume(v);
      }
    }
  }

  void _onScaleEnd(ScaleEndDetails d) {
    if (_seekPreview != null) {
      _c.seekTo(_seekPreview!);
      setState(() => _seekPreview = null);
    }
    _scheduleHide();
  }

  void _onDoubleTapDown(TapDownDetails d) {
    final w = MediaQuery.sizeOf(context).width;
    if (_c.is360.value) {
      _c.toggle();
      return;
    }
    if (d.globalPosition.dx < w / 4) {
      _c.seekBy(const Duration(seconds: -10));
      SmartDialog.showToast(
        '« 10s',
        displayTime: const Duration(milliseconds: 600),
      );
    } else if (d.globalPosition.dx > w * 3 / 4) {
      _c.seekBy(const Duration(seconds: 10));
      SmartDialog.showToast(
        '10s »',
        displayTime: const Duration(milliseconds: 600),
      );
    } else {
      _c.toggle();
    }
    _scheduleHide();
  }

  // ---------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _toggleControls,
        onDoubleTapDown: _onDoubleTapDown,
        onDoubleTap: () {},
        onScaleStart: _onScaleStart,
        onScaleUpdate: _onScaleUpdate,
        onScaleEnd: _onScaleEnd,
        child: Stack(
          fit: StackFit.expand,
          children: [
            _buildVideo(),
            _buildOverlays(),
          ],
        ),
      ),
    );
  }

  Widget _buildVideo() {
    return Obx(() {
      final texId = _c.textureId;
      if (texId == null || !_c.ready.value) {
        return const SizedBox.shrink();
      }
      final texture = Texture(textureId: texId);
      // 360° 由 libvlc 按视点渲染整幅输出, 铺满; 普通片源按视频宽高比
      if (_c.is360.value) {
        return texture;
      }
      return Center(
        child: AspectRatio(
          aspectRatio: _c.videoSize.value.aspect,
          child: texture,
        ),
      );
    });
  }

  Widget _buildOverlays() {
    return Obx(() {
      if (_c.error.value case final err?) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.error_outline,
                  color: Colors.redAccent,
                  size: 40,
                ),
                const SizedBox(height: 12),
                Text(
                  err,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
                const SizedBox(height: 16),
                FilledButton.tonal(
                  onPressed: () {
                    _c.error.value = null;
                    _open(Duration.zero);
                  },
                  child: const Text('重试'),
                ),
              ],
            ),
          ),
        );
      }
      return Stack(
        fit: StackFit.expand,
        children: [
          if (_c.buffering.value && !_c.playing.value)
            const Center(
              child: CircularProgressIndicator(color: Colors.white54),
            ),
          if (_seekPreview != null) _buildSeekPreview(),
          if (_c.is360.value) _build360Hud(),
          if (_showControls) ..._buildControls(),
        ],
      );
    });
  }

  Widget _buildSeekPreview() {
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.black54,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          '${DurationUtils.formatDuration(_seekPreview!.inSeconds)} / '
          '${DurationUtils.formatDuration(_c.length.value.inSeconds)}',
          style: const TextStyle(color: Colors.white, fontSize: 16),
        ),
      ),
    );
  }

  Widget _build360Hud() {
    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.only(top: 56),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(
            color: Colors.black45,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Text(
            '${_hudFormatLabel()}偏航 ${_c.vpYaw.value.toStringAsFixed(0)}°  '
            '俯仰 ${_c.vpPitch.value.toStringAsFixed(0)}°  '
            '视场 ${_c.vpFov.value.toStringAsFixed(0)}°'
            '${_c.vrRightEye.value ? '  右眼' : ''}',
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildControls() {
    return [
      // 顶栏(渐变底, 白字)
      DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.black54, Colors.transparent],
          ),
        ),
        child: SafeArea(
          bottom: false,
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back, color: Colors.white),
                onPressed: Get.back,
              ),
              Expanded(
                child: Text(
                  _entry.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 15),
                ),
              ),
              if (widget.playlist.length > 1)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Text(
                    '${_index + 1}/${widget.playlist.length}',
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 12,
                    ),
                  ),
                ),
              IconButton(
                tooltip: '音轨/字幕',
                icon: const Icon(Icons.playlist_play, color: Colors.white),
                onPressed: _showTrackSheet,
              ),
              PopupMenuButton<String>(
                tooltip: '更多',
                icon: const Icon(Icons.more_vert, color: Colors.white),
                color: Colors.black.withValues(alpha: 0.85),
                onSelected: _onMenu,
                itemBuilder: (context) => [
                  const PopupMenuItem(
                    value: 'speed',
                    child: Text('倍速…', style: _menuStyle),
                  ),
                  const PopupMenuItem(
                    value: 'scale',
                    child: Text('画面比例: 循环切换', style: _menuStyle),
                  ),
                  const PopupMenuItem(
                    value: 'rotate',
                    child: Text('旋转屏幕', style: _menuStyle),
                  ),
                  const PopupMenuItem(
                    value: 'vr',
                    child: Text('VR/全景…', style: _menuStyle),
                  ),
                  if (_c.is360.value) ...[
                    PopupMenuItem(
                      value: 'gyro',
                      child: Text(
                        _c.gyroOn.value ? '陀螺仪环视: 开' : '陀螺仪环视: 关',
                        style: _menuStyle,
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'recenter',
                      child: Text('视角摆正', style: _menuStyle),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
      // 中央 transport
      Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.playlist.length > 1)
              IconButton(
                iconSize: 34,
                icon: const Icon(Icons.skip_previous, color: Colors.white),
                onPressed: _index > 0 ? () => _switchTo(_index - 1) : null,
              ),
            IconButton(
              iconSize: 56,
              icon: Icon(
                _c.playing.value
                    ? Icons.pause_circle_filled
                    : Icons.play_circle_filled,
                color: Colors.white,
              ),
              onPressed: () {
                _c.toggle();
                _scheduleHide();
              },
            ),
            if (widget.playlist.length > 1)
              IconButton(
                iconSize: 34,
                icon: const Icon(Icons.skip_next, color: Colors.white),
                onPressed:
                    _index + 1 < widget.playlist.length
                        ? () => _switchTo(_index + 1)
                        : null,
              ),
          ],
        ),
      ),
      // 底栏
      Positioned(
        left: 8,
        right: 8,
        bottom: 0,
        child: DecoratedBox(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [Colors.black54, Colors.transparent],
            ),
          ),
          child: SafeArea(
            top: false,
            child: Row(
              children: [
                const SizedBox(width: 8),
                Text(
                  DurationUtils.formatDuration(
                    (_seekPreview ?? _c.position.value).inSeconds,
                  ),
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
                Expanded(
                  child: Slider(
                    value: (_seekPreview ?? _c.position.value)
                        .inMilliseconds
                        .toDouble()
                        .clamp(
                          0,
                          _c.length.value.inMilliseconds <= 0
                              ? 1
                              : _c.length.value.inMilliseconds,
                        )
                        .toDouble(),
                    onChangeStart: (_) => _hideTimer?.cancel(),
                    onChanged: _c.length.value > Duration.zero
                        ? (v) => setState(
                            () => _seekPreview =
                                Duration(milliseconds: v.round()),
                          )
                        : null,
                    onChangeEnd: (v) {
                      _c.seekTo(Duration(milliseconds: v.round()));
                      setState(() => _seekPreview = null);
                      _scheduleHide();
                    },
                  ),
                ),
                Text(
                  DurationUtils.formatDuration(_c.length.value.inSeconds),
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
                TextButton(
                  onPressed: _showSpeedSheet,
                  child: Text(
                    '${_c.rate.value}X',
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ),
                const SizedBox(width: 4),
              ],
            ),
          ),
        ),
      ),
    ];
  }

  static const TextStyle _menuStyle = TextStyle(color: Colors.white);

  void _onMenu(String action) {
    switch (action) {
      case 'speed':
        _showSpeedSheet();
      case 'scale':
        _cycleScale();
      case 'rotate':
        _rotate();
      case 'vr':
        _showVrSheet();
      case 'gyro':
        _c.setGyro(!_c.gyroOn.value);
      case 'recenter':
        _c.resetView();
        SmartDialog.showToast('视角已摆正');
    }
    _scheduleHide();
  }

  int _scaleIdx = 0;

  void _cycleScale() {
    _scaleIdx = (_scaleIdx + 1) % 3;
    const modes = ['bestFit', 'fill', 'fitScreen'];
    const labels = ['适应', '填充', '铺满'];
    _c.setScale(modes[_scaleIdx]);
    SmartDialog.showToast('画面: ${labels[_scaleIdx]}');
  }

  bool _landscapeForced = false;

  void _rotate() {
    _landscapeForced = !_landscapeForced;
    SystemChrome.setPreferredOrientations(
      _landscapeForced
          ? [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]
          : DeviceOrientation.values,
    );
  }

  String _hudFormatLabel() {
    final f = _c.vrFormat.value;
    if (f != VrFormat.auto) {
      return '${f.label}  ';
    }
    return _c.is360.value ? '360°(元数据)  ' : '';
  }

  /// 应用新的 VR 格式/眼位: 以当前进度原位重开(media 选项只在装载时生效)
  Future<void> _applyVr({VrFormat? format, bool? rightEye}) async {
    final pos = _c.position.value;
    setState(() {
      if (format != null) {
        _vrManual = format;
      }
      if (rightEye != null) {
        _vrRightEye = rightEye;
      }
    });
    await _open(
      pos > Duration.zero ? pos : Duration(milliseconds: _entry.startMs),
    );
  }

  Future<void> _showVrSheet() async {
    await _c.fetchEngineInfo();
    if (!mounted) {
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      builder: (sheetContext) => Obx(
        () {
          final cur = _effectiveVr;
          final patched = _c.enginePatched.value ?? true;
          return ListView(
            shrinkWrap: true,
            children: [
              const _SheetTitle('VR/全景格式'),
              for (final f in VrFormat.values)
                ListTile(
                  dense: true,
                  title: Text(f.label),
                  subtitle: f == VrFormat.auto
                      ? const Text('按片源元数据自动进入环视(官方行为)')
                      : null,
                  trailing: _check(f == cur, sheetContext),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _applyVr(format: f);
                  },
                ),
              if (!patched)
                const ListTile(
                  dense: true,
                  leading: Icon(Icons.info_outline, size: 18),
                  title: Text(
                    '当前为官方 libvlc 引擎(未含 VR 补丁): 强制格式不生效, 仅"自动"可用',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              const _SheetTitle('眼位(左右/上下格式生效)'),
              ListTile(
                dense: true,
                title: Text(_vrRightEye ? '右眼' : '左眼'),
                trailing: Switch(
                  value: _vrRightEye,
                  onChanged: (v) {
                    Navigator.of(sheetContext).pop();
                    _applyVr(rightEye: v);
                  },
                ),
              ),
              const _SheetTitle('自动识别'),
              ListTile(
                dense: true,
                title: const Text('按文件名识别 VR 格式'),
                subtitle: const Text('360/180/SBS/TB/VR/全景 等关键词; 识别不到时始终跟随元数据'),
                trailing: Switch(
                  value: Pref.vrAutoDetect,
                  onChanged: (v) {
                    GStorage.setting.put(SettingBoxKey.vrAutoDetect, v);
                    Navigator.of(sheetContext).pop();
                    if (_vrManual == null) {
                      _applyVr(); // 识别结果可能变化, 原位重开
                    }
                  },
                ),
              ),
              if (_c.engineVersion.value case final v?)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  child: Text(
                    '引擎: libvlc $v',
                    style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(sheetContext).colorScheme.outline,
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _showTrackSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      builder: (context) => Obx(
        () {
          final audios = _c.audioTracks;
          final spus = _c.spuTracks;
          return ListView(
            shrinkWrap: true,
            children: [
              if (audios.length > 1) ...[
                const _SheetTitle('音轨'),
                for (final t in audios)
                  ListTile(
                    dense: true,
                    title: Text(t.label),
                    trailing: _check(t.id == _c.curAudio.value, context),
                    onTap: () => _c.setAudioTrack(t.id),
                  ),
              ],
              const _SheetTitle('字幕'),
              for (final t in spus)
                ListTile(
                  dense: true,
                  title: Text(t.id == -1 ? '关闭' : t.label),
                  trailing: _check(t.id == _c.curSpu.value, context),
                  onTap: () => _c.setSpuTrack(t.id),
                ),
              if (spus.isEmpty)
                const ListTile(
                  dense: true,
                  title: Text('无字幕轨道(同名字幕文件会被自动加载)'),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget? _check(bool on, BuildContext context) => on
      ? Icon(Icons.check, size: 20, color: Theme.of(context).colorScheme.primary)
      : null;

  Future<void> _showSpeedSheet() async {
    var value = _c.rate.value;
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('${value.toStringAsFixed(1)}X'),
              Slider(
                min: 0.5,
                max: 4.0,
                divisions: 35,
                value: value.clamp(0.5, 4.0).toDouble(),
                onChanged: (v) {
                  setState(() => value = (v * 10).round() / 10);
                  _c.setRate(value);
                },
              ),
              Wrap(
                spacing: 8,
                children: [
                  for (final s in const [0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 4.0])
                    ActionChip(
                      label: Text('${s}X'),
                      onPressed: () {
                        setState(() => value = s);
                        _c.setRate(s);
                      },
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SheetTitle extends StatelessWidget {
  const _SheetTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 13,
        color: Theme.of(context).colorScheme.outline,
      ),
    ),
  );
}
