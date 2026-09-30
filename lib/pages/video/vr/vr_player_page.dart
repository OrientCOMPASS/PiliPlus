import 'dart:async';

import 'package:PiliPlus/common/widgets/flutter/pop_scope.dart';
import 'package:PiliPlus/plugin/pl_player/models/vr_projection.dart';
import 'package:PiliPlus/plugin/pl_player/utils/fullscreen.dart';
import 'package:PiliPlus/services/vr/vr_native_player.dart';
import 'package:PiliPlus/utils/duration_utils.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// 独立的 VR / 全景播放页（参考 xl_player 的交互）。
///
/// 为什么单独一页、而不是在 mpv 播放器上叠一层控制：
/// 这一页的画面**不经过 mpv** —— 解码、重投影、头追全在 native 侧
/// （`android/.../vr/`，MediaCodec + GLES2），视角是 uniform，每帧直接改，
/// 所以拖拽与陀螺仪都能逐帧跟手；mpv 的用户着色器只能把参数烘焙进源码，
/// 改一次就要重建整条渲染管线（详见 docs/piliplayer.md 9.1 / 10.1）。
///
/// 进入这一页时外层 mpv 播放器会被暂停，退出时恢复，不会两路同时出声。
class VrPlayerPage extends StatefulWidget {
  const VrPlayerPage({
    super.key,
    required this.uri,
    required this.title,
    this.headers,
    this.start = Duration.zero,
    this.projection = VrProjection.equirect360,
    this.eye = VrEye.left,
    this.fov = 90,
    this.gyro = true,
    this.onResumeOuter,
  });

  /// 交给 MediaExtractor 的地址：本机文件路径，或 http(s)（SMB 走本机回环代理）
  final String uri;
  final String title;
  final Map<String, String>? headers;
  final Duration start;
  final VrProjection projection;
  final VrEye eye;
  final double fov;
  final bool gyro;

  /// 退出本页时回调（外层用来恢复 mpv 播放）
  final VoidCallback? onResumeOuter;

  @override
  State<VrPlayerPage> createState() => _VrPlayerPageState();
}

class _VrPlayerPageState extends State<VrPlayerPage> {
  static const String _tag = 'vr_native_player';

  late final VrNativePlayerController _c = Get.put(
    VrNativePlayerController(
      initialProjection: widget.projection,
      initialEye: widget.eye,
      initialFov: widget.fov,
      initialGyro: widget.gyro,
    ),
    tag: _tag,
  );

  bool _showControls = true;
  Timer? _hideTimer;
  double _scaleBase = 90;

  /// 进来时系统栏是否可见: 只有这种情况下退出才需要恢复,
  /// 否则会把外层(全屏播放中)刻意隐藏的状态栏放出来
  late final bool _restoreSystemBar = showSystemBar_;

  @override
  void initState() {
    super.initState();
    hideSystemBar();
    fullMode();
    _open();
  }

  Future<void> _open() async {
    final ok = await _c.open(
      uri: widget.uri,
      headers: widget.headers,
      start: widget.start,
    );
    if (!mounted) {
      return;
    }
    if (!ok) {
      // 打不开就把原因摊出来, 别让用户面对黑屏
      setState(() => _showControls = true);
      return;
    }
    _scheduleHide();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    Get.delete<VrNativePlayerController>(tag: _tag);
    if (_restoreSystemBar) {
      showSystemBar();
    }
    super.dispose();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) {
        setState(() => _showControls = false);
      }
    });
  }

  void _toggleControls() {
    setState(() => _showControls = !_showControls);
    if (_showControls) {
      _scheduleHide();
    } else {
      _hideTimer?.cancel();
    }
  }


  @override
  Widget build(BuildContext context) {
    return popScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {
        // 退回外层播放页时恢复 mpv(进来时已暂停, 否则两路一起出声)
        if (didPop) {
          widget.onResumeOuter?.call();
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: LayoutBuilder(
          builder: (context, constraints) => GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _toggleControls,
            onScaleStart: (details) {
              _scaleBase = _c.fov.value;
            },
            onScaleUpdate: (details) {
              if (details.pointerCount > 1) {
                if (details.scale > 0) {
                  _c.setFov(_scaleBase / details.scale);
                }
                return;
              }
              _c.lookByPixels(
                details.focalPointDelta.dx,
                details.focalPointDelta.dy,
                width: constraints.maxWidth,
                height: constraints.maxHeight,
              );
              _scheduleHide();
            },
            child: Stack(
              fit: StackFit.expand,
              children: [
                _buildVideo(),
                if (_showControls) ..._buildControls(context),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildVideo() {
    // 必须包在 Obx 里读 ready: textureId 是普通字段, 直接在 build 里读的话
    // open() 完成后不会触发重建, 页面会一直停在"正在准备"
    return Obx(() {
      final id = _c.textureId;
      if (id == null || !_c.ready.value) {
        return const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            spacing: 12,
            children: [
              CircularProgressIndicator(color: Colors.white),
              Text(
                '正在准备 VR 播放器…',
                style: TextStyle(color: Colors.white),
              ),
            ],
          ),
        );
      }
      return Texture(textureId: id);
    });
  }

  List<Widget> _buildControls(BuildContext context) {
    return [
      // 半透明底, 保证按钮在亮色画面上也看得清
      const DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.black54, Colors.transparent, Colors.black54],
            stops: [0, 0.35, 1],
          ),
        ),
        child: SizedBox.expand(),
      ),
      _buildTopBar(context),
      _buildSideButtons(),
      _buildBottomBar(context),
      _buildCenterState(),
    ];
  }

  Widget _buildTopBar(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Row(
          children: [
            IconButton(
              tooltip: '退出 VR 播放器',
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(Icons.arrow_back, color: Colors.white),
            ),
            Expanded(
              child: Obx(
                () => Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                    ),
                    Text(
                      '偏航 ${_c.yaw.value.toStringAsFixed(1)}°  '
                      '俯仰 ${_c.pitch.value.toStringAsFixed(1)}°  '
                      '视场 ${_c.fov.value.toStringAsFixed(0)}°',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // 片源布局: 播放中随时切, 立刻生效(native 只改 uniform)
            Obx(
              () => PopupMenuButton<VrProjection>(
                tooltip: '片源布局',
                initialValue: _c.projection.value,
                icon: const Icon(Icons.view_in_ar, color: Colors.white),
                color: Colors.black87,
                onSelected: _c.setProjection,
                itemBuilder: (context) => [
                  for (final p in VrProjection.values)
                    if (p.enabled)
                      PopupMenuItem(value: p, child: Text(p.label)),
                ],
              ),
            ),
            Obx(
              () => _c.projection.value.isStereo
                  ? IconButton(
                      tooltip: '切换眼位',
                      onPressed: () => _c.setEye(
                        _c.eye.value == VrEye.left ? VrEye.right : VrEye.left,
                      ),
                      icon: const Icon(Icons.remove_red_eye_outlined,
                          color: Colors.white),
                    )
                  : const SizedBox.shrink(),
            ),
            Obx(
              () => IconButton(
                tooltip: _c.gyro.value ? '关闭陀螺仪' : '开启陀螺仪',
                onPressed: () => _c.setGyro(!_c.gyro.value),
                icon: Icon(
                  Icons.screen_rotation_outlined,
                  color: _c.gyro.value ? Colors.lightBlueAccent : Colors.white,
                ),
              ),
            ),
            IconButton(
              tooltip: '视角摆正',
              onPressed: () {
                _c.resetView();
                _scheduleHide();
              },
              icon: const Icon(Icons.center_focus_strong, color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSideButtons() {
    Widget look(IconData icon, double dyaw, double dpitch) => _StepButton(
      icon: icon,
      onStep: () => _c.lookBy(dyaw, dpitch),
      onStepEnd: _scheduleHide,
    );
    Widget zoom(IconData icon, double delta) => _StepButton(
      icon: icon,
      onStep: () => _c.setFov(_c.fov.value + delta),
      onStepEnd: _scheduleHide,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              look(Icons.keyboard_arrow_left, -10, 0),
              look(Icons.keyboard_arrow_right, 10, 0),
            ],
          ),
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              look(Icons.keyboard_arrow_up, 0, 10),
              look(Icons.keyboard_arrow_down, 0, -10),
              const SizedBox(height: 8),
              zoom(Icons.zoom_in, -8),
              zoom(Icons.zoom_out, 8),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCenterState() {
    return Obx(() {
      final err = _c.error.value;
      final ended = _c.ended.value;
      final buffering = _c.buffering.value;
      if (err != null) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              spacing: 10,
              children: [
                const Icon(Icons.error_outline, color: Colors.redAccent, size: 40),
                Text(
                  err,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
              ],
            ),
          ),
        );
      }
      if (ended) {
        return Center(
          child: FilledButton.tonalIcon(
            onPressed: () {
              // 级联写法: cascade_invocations 要求同一接收者的连续调用合并
              _c
                ..seek(Duration.zero)
                ..play();
            },
            icon: const Icon(Icons.replay),
            label: const Text('重新播放'),
          ),
        );
      }
      if (buffering) {
        return const Center(
          child: SizedBox.square(
            dimension: 40,
            child: CircularProgressIndicator(strokeWidth: 3, color: Colors.white),
          ),
        );
      }
      return const SizedBox.shrink();
    });
  }

  Widget _buildBottomBar(BuildContext context) {
    return Align(
      alignment: Alignment.bottomCenter,
      child: SafeArea(
        child: Obx(
          () {
            final total = _c.duration.value;
            final pos = _c.position.value;
            return Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
              child: Row(
                children: [
                  IconButton(
                    tooltip: _c.playing.value ? '暂停' : '播放',
                    onPressed: () {
                      _c.toggle();
                      _scheduleHide();
                    },
                    icon: Icon(
                      _c.playing.value ? Icons.pause : Icons.play_arrow,
                      color: Colors.white,
                    ),
                  ),
                  IconButton(
                    tooltip: '后退 10 秒',
                    onPressed: () {
                      _c.seekBy(const Duration(seconds: -10));
                      _scheduleHide();
                    },
                    icon: const Icon(Icons.replay_10, color: Colors.white),
                  ),
                  Text(
                    DurationUtils.formatDuration(pos.inSeconds),
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                  Expanded(
                    child: Slider(
                      value: total == Duration.zero
                          ? 0
                          : (pos.inMilliseconds / total.inMilliseconds)
                                .clamp(0.0, 1.0),
                      onChanged: total == Duration.zero
                          ? null
                          : (v) => _c.seek(
                              Duration(
                                milliseconds: (v * total.inMilliseconds).round(),
                              ),
                            ),
                    ),
                  ),
                  Text(
                    DurationUtils.formatDuration(total.inSeconds),
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                  IconButton(
                    tooltip: '前进 10 秒',
                    onPressed: () {
                      _c.seekBy(const Duration(seconds: 10));
                      _scheduleHide();
                    },
                    icon: const Icon(Icons.forward_10, color: Colors.white),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// 步进按钮：点一下走一步，按住每 120ms 连续走（与 mpv 版 VR 控制层同手感）。
///
/// 只用 tap 系列回调，不挂 onLongPress*：长按识别器和 tap 识别器会在竞技场里
/// 互抢，出现「按住不连续 / 松手不生效」。按住不放时 tap 识别器不会结束，
/// 定时器就一直走；抬手或被判负（onTapCancel）都会停。
class _StepButton extends StatefulWidget {
  const _StepButton({
    required this.icon,
    required this.onStep,
    this.onStepEnd,
  });

  final IconData icon;
  final VoidCallback onStep;
  final VoidCallback? onStepEnd;

  @override
  State<_StepButton> createState() => _StepButtonState();
}

class _StepButtonState extends State<_StepButton> {
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _start() {
    widget.onStep();
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 120), (_) {
      widget.onStep();
    });
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
    widget.onStepEnd?.call();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _start(),
      onTapUp: (_) => _stop(),
      onTapCancel: _stop,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: CircleAvatar(
          radius: 20,
          backgroundColor: Colors.black45,
          child: Icon(widget.icon, color: Colors.white, size: 22),
        ),
      ),
    );
  }
}
