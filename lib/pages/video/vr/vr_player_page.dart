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
  bool _debugOverlay = false;
  Timer? _hideTimer;
  double _scaleBase = 90;
  Size _lastReportedSize = Size.zero;

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
          builder: (context, constraints) {
            // 把渲染目标的真实尺寸(设备像素)告诉 native。
            // Flutter 不会替插件设 SurfaceTexture 的 defaultBufferSize,
            // 不设就是 0x0 -> EGL 只交换出 1 个像素 -> Flutter 拉伸铺满全屏,
            // 整个画面就是一个纯色(第一版真机反馈的"解码出来是纯色"就是这个)。
            _reportRenderSize(context, constraints);
            return GestureDetector(
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
              // Stack 的非定位子项在 StackFit.expand 下会拿到**全屏 tight 约束**,
              // 直接塞 Row/SafeArea 会被拉满整屏、内容垂直居中 —— 第一版
              // "所有控件都跑到屏幕中间"就是这么来的。一律用 Positioned 定位。
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _buildVideo(),
                  if (_showControls) ...[
                    const Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.black54,
                              Colors.transparent,
                              Colors.black54,
                            ],
                            stops: [0, 0.35, 1],
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: _buildTopBar(context),
                    ),
                    Positioned(
                      left: 6,
                      top: 0,
                      bottom: 0,
                      child: Center(child: _leftButtons()),
                    ),
                    Positioned(
                      right: 6,
                      top: 0,
                      bottom: 0,
                      child: Center(child: _rightButtons()),
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: _buildBottomBar(context),
                    ),
                  ],
                  if (_debugOverlay) _buildDebugOverlay(),
                  // 错误/缓冲/播完 的状态不受控件显隐影响, 一直可见
                  Center(child: _buildCenterState()),
                ],
              ),
            );
          },
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

  /// 渲染目标尺寸(设备像素)有变化时报给 native, 只在变化时报
  void _reportRenderSize(BuildContext context, BoxConstraints constraints) {
    if (!constraints.hasBoundedWidth || !constraints.hasBoundedHeight) {
      return;
    }
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final size = Size(
      (constraints.maxWidth * dpr).roundToDouble(),
      (constraints.maxHeight * dpr).roundToDouble(),
    );
    if (size == _lastReportedSize) {
      return;
    }
    _lastReportedSize = size;
    _c.setRenderSize(size.width.toInt(), size.height.toInt());
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
                      icon: const Icon(
                        Icons.remove_red_eye_outlined,
                        color: Colors.white,
                      ),
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
            IconButton(
              tooltip: '诊断信息',
              onPressed: () => setState(() => _debugOverlay = !_debugOverlay),
              icon: Icon(
                Icons.bug_report_outlined,
                color: _debugOverlay ? Colors.amberAccent : Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _lookButton(IconData icon, double dyaw, double dpitch) => _StepButton(
    icon: icon,
    onStep: () => _c.lookBy(dyaw, dpitch),
    onStepEnd: _scheduleHide,
  );

  Widget _zoomButton(IconData icon, double delta) => _StepButton(
    icon: icon,
    onStep: () => _c.setFov(_c.fov.value + delta),
    onStepEnd: _scheduleHide,
  );

  Widget _leftButtons() => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      _lookButton(Icons.keyboard_arrow_left, -10, 0),
      _lookButton(Icons.keyboard_arrow_right, 10, 0),
    ],
  );

  Widget _rightButtons() => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      _lookButton(Icons.keyboard_arrow_up, 0, 10),
      _lookButton(Icons.keyboard_arrow_down, 0, -10),
      const SizedBox(height: 8),
      _zoomButton(Icons.zoom_in, -8),
      _zoomButton(Icons.zoom_out, 8),
    ],
  );

  /// 诊断浮层: native 每 100ms 回报一行(渲染尺寸/解码帧数/渲染帧数/GL 错误),
  /// 外加「原画直通」开关 —— 直通有画面说明解码与纹理链路是好的、问题在投影,
  /// 直通仍是纯色说明问题在解码/纹理。真机截图就能定位, 不用来回猜。
  Widget _buildDebugOverlay() {
    return Positioned(
      left: 8,
      right: 8,
      bottom: 64,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Obx(
            () => Text(
              _c.debug.value.isEmpty ? '等待 native 回报…' : _c.debug.value,
              style: const TextStyle(
                color: Colors.amberAccent,
                fontSize: 11,
                height: 1.4,
                shadows: [Shadow(color: Colors.black, blurRadius: 4)],
              ),
            ),
          ),
          const SizedBox(height: 6),
          Obx(
            () => ActionChip(
              label: Text(_c.passthrough.value ? '退出原画直通' : '原画直通(诊断)'),
              avatar: const Icon(Icons.image_outlined, size: 16),
              onPressed: () => _c.setPassthrough(!_c.passthrough.value),
            ),
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
                const Icon(
                  Icons.error_outline,
                  color: Colors.redAccent,
                  size: 40,
                ),
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
            child: CircularProgressIndicator(
              strokeWidth: 3,
              color: Colors.white,
            ),
          ),
        );
      }
      return const SizedBox.shrink();
    });
  }

  Widget _buildBottomBar(BuildContext context) {
    return SafeArea(
      top: false,
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
                        : (pos.inMilliseconds / total.inMilliseconds).clamp(
                            0.0,
                            1.0,
                          ),
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
