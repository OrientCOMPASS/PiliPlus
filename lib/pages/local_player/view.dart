import 'dart:async';

import 'package:PiliPlus/pages/local_player/controller.dart';
import 'package:PiliPlus/services/local_media/models.dart';
import 'package:PiliPlus/utils/duration_utils.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// 本地/局域网统一播放页（libvlc 引擎）。
///
/// 不包含任何依赖 B 站接口的功能（弹幕/点赞/投币/收藏/分享/稍后再看/
/// 看点/AI 字幕/画质切换/进度预览图）。保留纯本地能力：进度条拖动、
/// 截图、定时关闭、倍速、字幕、音轨、比例、旋转锁、播放列表、VR。
class LocalPlayerPage extends StatefulWidget {
  const LocalPlayerPage({super.key});

  @override
  State<LocalPlayerPage> createState() => _LocalPlayerPageState();
}

class _LocalPlayerPageState extends State<LocalPlayerPage> {
  final LocalPlayerController _c = Get.arguments as LocalPlayerController;

  // gesture state
  _GestureMode _mode = _GestureMode.none;
  int _dragSeekTargetMs = 0;
  int _dragSeekStartMs = 0;
  Offset _panStart = Offset.zero;
  Offset _panLast = Offset.zero;
  double _vrPinchStartFov = 80;
  bool _longPressSpeeding = false;
  double _rateBeforeLongPress = 1.0;
  double _sliderValue = -1;

  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _c.initBrightnessVolume();
    _c.bumpControls();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    WakelockPlus.disable();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  void _bumpControls() {
    _c.showControls.value = true;
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (_c.playing.value) _c.showControls.value = false;
    });
  }

  // ---- gestures ----

  void _onDoubleTapDown(TapDownDetails d) {
    if (!Pref.enableQuickDouble) {
      _c.togglePlay();
      _bumpControls();
      return;
    }
    final width = MediaQuery.sizeOf(context).width;
    final deltaSec = Pref.fastForBackwardDuration;
    if (d.globalPosition.dx < width / 2) {
      _c.seekBy(-deltaSec * 1000);
      _flashSeekIcon(-deltaSec);
    } else {
      _c.seekBy(deltaSec * 1000);
      _flashSeekIcon(deltaSec);
    }
    _bumpControls();
  }

  void _flashSeekIcon(int seconds) {
    SmartDialog.showToast(
      seconds > 0 ? '快进 $seconds 秒' : '快退 ${-seconds} 秒',
      duration: const Duration(milliseconds: 600),
    );
  }

  void _onScaleStart(ScaleStartDetails d, BoxConstraints box) {
    _panStart = d.focalPoint;
    _panLast = d.focalPoint;
    if (d.pointerCount >= 2) {
      if (_c.vrActive.value) {
        _mode = _GestureMode.vrPinch;
        _vrPinchStartFov = _c.vpFov.value;
      } else {
        _mode = _GestureMode.none;
      }
      return;
    }
    _mode = _GestureMode.undecided;
  }

  void _onScaleUpdate(ScaleUpdateDetails d, BoxConstraints box) {
    if (_mode == _GestureMode.vrPinch) {
      if (d.pointerCount >= 2) {
        // 双指缩放视场角
        _c.setFov(_vrPinchStartFov / d.scale.clamp(0.3, 3.0));
      }
      return;
    }
    if (_mode == _GestureMode.none) return;

    final total = d.focalPoint - _panStart;
    final delta = d.focalPoint - _panLast;
    _panLast = d.focalPoint;

    if (_mode == _GestureMode.undecided) {
      const slop = 18.0;
      if (total.distance < slop) return;
      if (_c.vrActive.value) {
        _mode = _GestureMode.vrPan;
      } else if (total.dx.abs() > total.dy.abs()) {
        _mode = _GestureMode.seekH;
        _dragSeekStartMs = _c.positionMs.value;
        _dragSeekTargetMs = _dragSeekStartMs;
      } else if (Pref.enableSlideVolumeBrightness) {
        final leftSide = _panStart.dx < box.maxWidth / 2;
        _mode = leftSide ? _GestureMode.brightV : _GestureMode.volV;
      } else {
        _mode = _GestureMode.seekH;
        _dragSeekStartMs = _c.positionMs.value;
        _dragSeekTargetMs = _dragSeekStartMs;
      }
    }

    switch (_mode) {
      case _GestureMode.vrPan:
        // 单指拖拽环视：约 0.25°/px
        _c.dragViewpoint(-delta.dx * 0.25, delta.dy * 0.25);
      case _GestureMode.seekH:
        final duration = _c.durationMs.value;
        if (duration <= 0) return;
        int deltaMs;
        if (Pref.useRelativeSlide) {
          deltaMs = (total.dx / box.maxWidth * duration * Pref.sliderDuration / 100).round();
        } else {
          deltaMs = (total.dx / box.maxWidth * Pref.sliderDuration * 1000).round();
        }
        _dragSeekTargetMs = (_dragSeekStartMs + deltaMs).clamp(0, duration);
        setState(() {});
      case _GestureMode.brightV:
        _c.setBrightness(_c.brightness - delta.dy / box.maxHeight);
        setState(() {});
      case _GestureMode.volV:
        _c.setVolume(_c.volume - delta.dy / box.maxHeight);
        setState(() {});
      case _GestureMode.none:
      case _GestureMode.undecided:
      case _GestureMode.vrPinch:
        break;
    }
  }

  void _onScaleEnd(ScaleEndDetails d) {
    if (_mode == _GestureMode.seekH) {
      _c.seekTo(_dragSeekTargetMs);
    }
    _mode = _GestureMode.none;
    if (mounted) setState(() {});
  }

  // ---- build ----

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: LayoutBuilder(
        builder: (context, box) {
          return Stack(
            fit: StackFit.expand,
            children: [
              // 画面（PlatformView，控件叠在其上）
              AndroidView(
                viewType: 'piliplus/vlc_video',
                onPlatformViewCreated: _c.attachView,
                creationParams: const <String, dynamic>{},
                creationParamsCodec: const StandardMessageCodec(),
                layoutDirection: TextDirection.ltr,
              ),
              // 手势层
              _buildGestureLayer(box),
              // 指示器 / HUD / 控件
              _buildIndicators(),
              Obx(() => _c.showControls.value ? _buildTopBar() : const SizedBox.shrink()),
              Obx(() => _c.showControls.value ? _buildBottomBar() : const SizedBox.shrink()),
              Obx(() => _c.status.value == LocalPlayStatus.error ? _buildError() : const SizedBox.shrink()),
            ],
          );
        },
      ),
    );
  }

  Widget _buildGestureLayer(BoxConstraints box) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _bumpControls,
      onDoubleTapDown: _onDoubleTapDown,
      onDoubleTap: () {},
      onLongPressStart: (_) {
        if (_c.playing.value && !_longPressSpeeding) {
          _longPressSpeeding = true;
          _rateBeforeLongPress = _c.rate.value;
          _c.setRate(Pref.longPressSpeedDefault);
          SmartDialog.showToast(
            '${Pref.longPressSpeedDefault}x 中…',
            duration: const Duration(milliseconds: 600),
          );
        }
      },
      onLongPressEnd: (_) {
        if (_longPressSpeeding) {
          _longPressSpeeding = false;
          _c.setRate(_rateBeforeLongPress);
        }
      },
      onScaleStart: (d) => _onScaleStart(d, box),
      onScaleUpdate: (d) => _onScaleUpdate(d, box),
      onScaleEnd: _onScaleEnd,
      child: const SizedBox.expand(),
    );
  }

  Widget _buildIndicators() {
    return Stack(
      fit: StackFit.expand,
      children: [
        // 拖动快进/快退目标时间预览
        if (_mode == _GestureMode.seekH)
          Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${DurationUtils.formatDuration(_dragSeekTargetMs ~/ 1000)} / '
                    '${DurationUtils.formatDuration(_c.durationMs.value ~/ 1000)}',
                    style: const TextStyle(color: Colors.white, fontSize: 18),
                  ),
                  Text(
                    (_dragSeekTargetMs >= _dragSeekStartMs ? '+' : '') +
                        DurationUtils.formatDuration(
                          (_dragSeekTargetMs - _dragSeekStartMs) ~/ 1000,
                        ),
                    style: TextStyle(
                      color: (_dragSeekTargetMs >= _dragSeekStartMs)
                          ? Colors.greenAccent
                          : Colors.orangeAccent,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ),
          ),
        // 亮度/音量指示
        if (_mode == _GestureMode.brightV || _mode == _GestureMode.volV)
          Align(
            alignment: _mode == _GestureMode.brightV ? Alignment.centerLeft : Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _mode == _GestureMode.brightV ? Icons.brightness_6 : Icons.volume_up,
                      color: Colors.white,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${((_mode == _GestureMode.brightV ? _c.brightness : _c.volume) * 100).round()}%',
                      style: const TextStyle(color: Colors.white),
                    ),
                  ],
                ),
              ),
            ),
          ),
        // 缓冲指示
        Obx(() {
          final buffering = _c.buffering.value;
          final show = _c.status.value == LocalPlayStatus.opening ||
              (buffering > 0 && buffering < 100 && !_c.playing.value);
          if (!show) return const SizedBox.shrink();
          return const Center(child: CircularProgressIndicator(color: Colors.white));
        }),
        // VR HUD：偏航/俯仰/视场读数
        Positioned(
          top: 64,
          right: 12,
          child: Obx(() {
            if (!_c.vrActive.value || !_c.showControls.value) {
              return const SizedBox.shrink();
            }
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.black45,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '偏航 ${_c.vpYaw.value.toStringAsFixed(1)}°',
                    style: const TextStyle(color: Colors.white70, fontSize: 11),
                  ),
                  Text(
                    '俯仰 ${_c.vpPitch.value.toStringAsFixed(1)}°',
                    style: const TextStyle(color: Colors.white70, fontSize: 11),
                  ),
                  Text(
                    '视场 ${_c.vpFov.value.toStringAsFixed(0)}°',
                    style: const TextStyle(color: Colors.white70, fontSize: 11),
                  ),
                ],
              ),
            );
          }),
        ),
      ],
    );
  }

  Widget _buildTopBar() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
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
                onPressed: () => Get.back(),
              ),
              Expanded(
                child: Obx(
                  () => Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _c.currentTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontSize: 15),
                      ),
                      if (_c.uris.length > 1)
                        Text(
                          '${_c.index.value + 1}/${_c.uris.length} · ${_c.playlistName}',
                          style: const TextStyle(color: Colors.white60, fontSize: 11),
                        ),
                    ],
                  ),
                ),
              ),
              // VR 快捷：摆正 / 陀螺仪
              Obx(() {
                if (!_c.vrActive.value) return const SizedBox.shrink();
                return Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.center_focus_strong, color: Colors.white),
                      tooltip: '视角摆正',
                      onPressed: _c.recenterViewpoint,
                    ),
                    IconButton(
                      icon: Icon(
                        _c.gyroEnabled.value ? Icons.explore : Icons.explore_outlined,
                        color: _c.gyroEnabled.value ? Colors.lightBlueAccent : Colors.white,
                      ),
                      tooltip: '陀螺仪环视',
                      onPressed: () => _c.toggleGyro(),
                    ),
                  ],
                );
              }),
              Obx(
                () => IconButton(
                  icon: Icon(
                    _c.sleepMinutes.value > 0 ? Icons.bedtime : Icons.bedtime_outlined,
                    color: _c.sleepMinutes.value > 0 ? Colors.amberAccent : Colors.white,
                  ),
                  tooltip: '定时关闭',
                  onPressed: _showSleepMenu,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.playlist_play, color: Colors.white),
                tooltip: '播放列表',
                onPressed: _showPlaylistSheet,
              ),
              IconButton(
                icon: const Icon(Icons.more_vert, color: Colors.white),
                onPressed: _showMoreMenu,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomBar() {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [Colors.black87, Colors.transparent],
          ),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 进度条
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Obx(() {
                  final duration = _c.durationMs.value;
                  final position = _mode == _GestureMode.seekH
                      ? _dragSeekTargetMs
                      : (_sliderValue >= 0 ? _sliderValue.round() : _c.positionMs.value);
                  return Row(
                    children: [
                      Text(
                        DurationUtils.formatDuration(position ~/ 1000),
                        style: const TextStyle(color: Colors.white, fontSize: 12),
                      ),
                      Expanded(
                        child: Slider(
                          value: duration == 0
                              ? 0
                              : (position / duration).clamp(0.0, 1.0).toDouble(),
                          onChanged: (v) {
                            setState(() => _sliderValue = v * duration);
                          },
                          onChangeEnd: (v) {
                            _c.seekTo((v * duration).round());
                            setState(() => _sliderValue = -1);
                          },
                        ),
                      ),
                      Text(
                        DurationUtils.formatDuration(duration ~/ 1000),
                        style: const TextStyle(color: Colors.white, fontSize: 12),
                      ),
                    ],
                  );
                }),
              ),
              // 控制按钮行
              Row(
                children: [
                  IconButton(
                    icon: Icon(
                      _c.playing.value ? Icons.pause : Icons.play_arrow,
                      color: Colors.white,
                    ),
                    onPressed: () {
                      _c.togglePlay();
                      _bumpControls();
                    },
                  ),
                  if (_c.uris.length > 1)
                    IconButton(
                      icon: const Icon(Icons.skip_previous, color: Colors.white),
                      onPressed: _c.playPrev,
                    ),
                  if (_c.uris.length > 1)
                    IconButton(
                      icon: const Icon(Icons.skip_next, color: Colors.white),
                      onPressed: () => _c.playNext(),
                    ),
                  // 倍速
                  Obx(
                    () => TextButton(
                      onPressed: _showSpeedSheet,
                      child: Text(
                        '${_c.rate.value}x',
                        style: TextStyle(
                          color: _c.rate.value == 1.0 ? Colors.white : Colors.amberAccent,
                        ),
                      ),
                    ),
                  ),
                  // 字幕（常驻当前生效字幕短标签）
                  Obx(
                    () => TextButton.icon(
                      onPressed: _showSubtitleSheet,
                      icon: const Icon(Icons.subtitles_outlined, color: Colors.white, size: 20),
                      label: Text(
                        _c.spuLabel.value,
                        style: const TextStyle(color: Colors.white70, fontSize: 12),
                      ),
                    ),
                  ),
                  // 音轨
                  IconButton(
                    icon: const Icon(Icons.audiotrack_outlined, color: Colors.white),
                    tooltip: '音轨',
                    onPressed: _showAudioSheet,
                  ),
                  // VR
                  Obx(
                    () => IconButton(
                      icon: Icon(
                        Icons.vrpano,
                        color: _c.vrActive.value ? Colors.lightBlueAccent : Colors.white,
                      ),
                      tooltip: 'VR / 全景',
                      onPressed: _showVrSheet,
                    ),
                  ),
                  const Spacer(),
                  // 画面比例
                  Obx(
                    () => IconButton(
                      icon: const Icon(Icons.aspect_ratio, color: Colors.white),
                      tooltip: '画面比例：${_c.aspectLabel}',
                      onPressed: () {
                        _c.cycleAspect();
                        SmartDialog.showToast('画面比例：${_c.aspectLabel}',
                            duration: const Duration(milliseconds: 700));
                        _bumpControls();
                      },
                    ),
                  ),
                  // 旋转锁定
                  Obx(
                    () => IconButton(
                      icon: Icon(
                        _c.rotationLocked.value
                            ? Icons.screen_lock_rotation
                            : Icons.screen_rotation,
                        color: _c.rotationLocked.value ? Colors.amberAccent : Colors.white,
                      ),
                      tooltip: '屏幕旋转锁定',
                      onPressed: () {
                        _c.toggleRotationLock();
                        _bumpControls();
                      },
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Container(
        margin: const EdgeInsets.all(24),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Colors.black87,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.redAccent.withValues(alpha: 0.5)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: Colors.redAccent, size: 40),
            const SizedBox(height: 12),
            Obx(
              () => Text(
                _c.errorMessage.value.isEmpty ? '播放失败' : _c.errorMessage.value,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              '可在「设置 → 关于 → 引擎日志」查看详细错误并导出诊断文件',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white60, fontSize: 12),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton(
                  onPressed: () => Get.back(),
                  child: const Text('返回', style: TextStyle(color: Colors.white70)),
                ),
                const SizedBox(width: 12),
                FilledButton(
                  onPressed: _c.retry,
                  child: const Text('重试'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ---- sheets & menus ----

  void _showSleepMenu() {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('定时关闭'),
            ),
            for (final m in [0, 15, 30, 45, 60])
              Obx(
                () => RadioListTile<int>(
                  value: m,
                  groupValue: _c.sleepMinutes.value,
                  title: Text(m == 0 ? '关闭定时' : '$m 分钟后暂停'),
                  onChanged: (v) {
                    if (v != null) _c.setSleepTimer(v);
                    Navigator.pop(context);
                    if (m > 0) SmartDialog.showToast('将在 $m 分钟后暂停播放');
                  },
                ),
              ),
          ],
        ),
      ),
    );
    _bumpControls();
  }

  void _showPlaylistSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.5,
        builder: (context, scrollController) => Column(
          children: [
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('播放列表（同目录视频，列表循环）'),
            ),
            Expanded(
              child: Obx(
                () => ListView.builder(
                  controller: scrollController,
                  itemCount: _c.uris.length,
                  itemBuilder: (context, i) {
                    final selected = i == _c.index.value;
                    return ListTile(
                      leading: Icon(
                        selected ? Icons.play_arrow : Icons.movie_outlined,
                        color: selected ? Theme.of(context).colorScheme.primary : null,
                      ),
                      title: Text(
                        i < _c.titles.length ? _c.titles[i] : _c.uris[i],
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      selected: selected,
                      onTap: () {
                        _c.playIndex(i, resume: true);
                        Navigator.pop(context);
                      },
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
    _bumpControls();
  }

  void _showMoreMenu() {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('截图'),
              onTap: () {
                Navigator.pop(context);
                _c.takeSnapshot().then((_) => SmartDialog.showToast('截图处理中…'));
              },
            ),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('播放信息'),
              onTap: () {
                Navigator.pop(context);
                _showInfoDialog();
              },
            ),
            if (_c.isNetwork)
              ListTile(
                leading: const Icon(Icons.link),
                title: const Text('复制来源地址（脱敏）'),
                onTap: () {
                  Navigator.pop(context);
                  Clipboard.setData(
                    ClipboardData(
                      text: _c.currentUri.replaceFirstMapped(
                        RegExp(r'://([^/@:]+):([^@/]+)@'),
                        (m) => '://${m.group(1)}:***@',
                      ),
                    ),
                  );
                  SmartDialog.showToast('已复制（密码已脱敏）');
                },
              ),
          ],
        ),
      ),
    );
    _bumpControls();
  }

  void _showInfoDialog() {
    showDialog<void>(
      context: context,
      builder: (context) => Obx(
        () => AlertDialog(
          title: const Text('播放信息'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText('标题：${_c.currentTitle}'),
              SelectableText(
                '来源：${_c.isNetwork ? '局域网' : '本机'}',
              ),
              SelectableText(
                _c.isNetwork
                    ? '地址：${_c.currentUri.replaceFirstMapped(RegExp(r'://([^/@:]+):([^@/]+)@'), (m) => '://${m.group(1)}:***@')}'
                    : '路径：${_c.index.value < _c.titles.length ? _c.titles[_c.index.value] : _c.currentUri}',
              ),
              SelectableText('时长：${DurationUtils.formatDuration(_c.durationMs.value ~/ 1000)}'),
              SelectableText('引擎：libvlc ${_c.vrEngineVersion.value > 0 ? '(VR 定制版 v${_c.vrEngineVersion.value})' : '(标准版，无 VR 扩展)'}'),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('关闭')),
          ],
        ),
      ),
    );
  }

  void _showSpeedSheet() {
    final presets = Pref.speedList;
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('倍速（滑条 0.5–4.0，步进 0.1）'),
              const SizedBox(height: 8),
              Obx(
                () => Row(
                  children: [
                    Text('${_c.rate.value.toStringAsFixed(1)}x'),
                    Expanded(
                      child: Slider(
                        value: _c.rate.value.clamp(0.5, 4.0),
                        min: 0.5,
                        max: 4.0,
                        divisions: 35,
                        label: '${_c.rate.value.toStringAsFixed(1)}x',
                        onChanged: (v) => _c.setRate(double.parse(v.toStringAsFixed(1))),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 8,
                children: presets
                    .map(
                      (s) => Obx(
                        () => ChoiceChip(
                          label: Text('$s x'),
                          selected: (_c.rate.value - s).abs() < 0.001,
                          onSelected: (_) {
                            _c.setRate(s);
                            Navigator.pop(context);
                          },
                        ),
                      ),
                    )
                    .toList(),
              ),
            ],
          ),
        ),
      ),
    );
    _bumpControls();
  }

  Future<void> _showSubtitleSheet() async {
    await _c.refreshTracks();
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.45,
        builder: (context, scrollController) => Column(
          children: [
            const Padding(padding: EdgeInsets.all(12), child: Text('字幕')),
            Expanded(
              child: Obx(
                () => ListView(
                  controller: scrollController,
                  children: [
                    RadioListTile<int>(
                      value: -1,
                      groupValue: _c.selSpu.value,
                      title: const Text('关闭字幕'),
                      onChanged: (v) {
                        if (v != null) _c.selectSpuTrack(v);
                      },
                    ),
                    ..._c.spuTracks.map(
                      (t) {
                        final id = (t['id'] as num?)?.toInt() ?? -2;
                        final name = (t['name'] as String? ?? '').isEmpty
                            ? '轨道 $id'
                            : t['name'] as String;
                        return RadioListTile<int>(
                          value: id,
                          groupValue: _c.selSpu.value,
                          title: Text(name),
                          onChanged: (v) {
                            if (v != null) _c.selectSpuTrack(v);
                          },
                        );
                      },
                    ),
                    const Divider(),
                    ListTile(
                      leading: const Icon(Icons.file_open_outlined),
                      title: const Text('加载外挂字幕…'),
                      onTap: () async {
                        Navigator.pop(context);
                        final result = await FilePicker.pickFile(
                          type: .custom,
                          allowedExtensions: const ['srt', 'ass', 'ssa', 'sub', 'idx', 'vtt'],
                        );
                        final p = result?.xFile.path;
                        if (p != null) {
                          await _c.addSubtitleFile(p);
                          SmartDialog.showToast('已尝试加载外挂字幕');
                          _c.refreshTracks();
                        }
                      },
                    ),
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: Text(
                        '同名外挂字幕（.srt/.ass/.ssa/.vtt/.sub/.idx）会在打开本地文件时自动探测加载。',
                        style: TextStyle(fontSize: 11, color: Colors.grey),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
    _bumpControls();
  }

  Future<void> _showAudioSheet() async {
    await _c.refreshTracks();
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Obx(
          () => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(padding: EdgeInsets.all(12), child: Text('音轨')),
              if (_c.audioTracks.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('无可用音轨信息'),
                ),
              ..._c.audioTracks.map((t) {
                final id = (t['id'] as num?)?.toInt() ?? -2;
                final name = (t['name'] as String? ?? '').isEmpty
                    ? '轨道 $id'
                    : t['name'] as String;
                return RadioListTile<int>(
                  value: id,
                  groupValue: _c.selAudio.value,
                  title: Text(name),
                  onChanged: (v) {
                    if (v != null) _c.selectAudioTrack(v);
                    Navigator.pop(context);
                  },
                );
              }),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
    _bumpControls();
  }

  void _showVrSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: Obx(
          () => Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Text('VR / 全景', style: TextStyle(fontSize: 16)),
                    const Spacer(),
                    Text(
                      _c.vrEngineVersion.value > 0
                          ? '引擎：VR 定制版 libvlc (v${_c.vrEngineVersion.value})'
                          : '引擎：标准 libvlc',
                      style: const TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                  ],
                ),
                if (_c.vrUnsupported.value)
                  Container(
                    margin: const EdgeInsets.only(top: 8),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.orange.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.orange),
                    ),
                    child: const Text(
                      '当前运行引擎不具备 VR 扩展能力（非定制 libvlc）。VR 矩阵功能不可用，请使用带 libvlc-pvr 的构建。',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                const SizedBox(height: 12),
                const Text('投影格式'),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  children: VrProjection.values
                      .map(
                        (p) => ChoiceChip(
                          label: Text(p.label),
                          selected: _c.vrProjection.value == p,
                          onSelected: (_) => _c.setVrProjection(p),
                        ),
                      )
                      .toList(),
                ),
                const SizedBox(height: 12),
                const Text('立体布局'),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  children: VrStereo.values
                      .map(
                        (s) => ChoiceChip(
                          label: Text(s.label),
                          selected: _c.vrStereo.value == s,
                          onSelected: (_) => _c.setVrStereo(s),
                        ),
                      )
                      .toList(),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        value: _c.gyroEnabled.value,
                        title: const Text('陀螺仪环视'),
                        onChanged: _c.gyroAvailable.value
                            ? (v) => _c.toggleGyro(v)
                            : null,
                      ),
                    ),
                    TextButton.icon(
                      onPressed: _c.recenterViewpoint,
                      icon: const Icon(Icons.center_focus_strong),
                      label: const Text('视角摆正'),
                    ),
                  ],
                ),
                Obx(() {
                  final stereo = _c.vrStereo.value;
                  final isStereo = stereo == VrStereo.sbs || stereo == VrStereo.tb;
                  if (!isStereo) return const SizedBox.shrink();
                  return Row(
                    children: [
                      const Text('眼位：'),
                      ChoiceChip(
                        label: const Text('左眼'),
                        selected: _c.vrEye.value == VrEye.left,
                        onSelected: (_) {
                          if (_c.vrEye.value != VrEye.left) _c.toggleEye();
                        },
                      ),
                      const SizedBox(width: 8),
                      ChoiceChip(
                        label: const Text('右眼'),
                        selected: _c.vrEye.value == VrEye.right,
                        onSelected: (_) {
                          if (_c.vrEye.value != VrEye.right) _c.toggleEye();
                        },
                      ),
                    ],
                  );
                }),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Text('视场角'),
                    Expanded(
                      child: Slider(
                        value: _c.vpFov.value.clamp(20.0, 140.0),
                        min: 20,
                        max: 140,
                        divisions: 24,
                        label: '${_c.vpFov.value.round()}°',
                        onChanged: _c.setFov,
                      ),
                    ),
                    Text('${_c.vpFov.value.round()}°'),
                  ],
                ),
                const Text(
                  '提示：切换格式/眼位会保留当前进度原位生效；180° 片源手动偏航在覆盖边界收敛。'
                  '文件名自动识别可在 设置 → 播放设置 中开关。',
                  style: TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    _bumpControls();
  }
}

enum _GestureMode { none, undecided, seekH, brightV, volV, vrPan, vrPinch }
