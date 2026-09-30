import 'dart:async';

import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/vr_projection.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// VR 控制层。
///
/// 只有进入「VR 控制模式」后才会被挂到控件树上(此时播放器原有的
/// MouseInteractiveViewer 不在树里), 因此不会与 PiliPlus 的手势争抢:
///   * 单指拖拽 = 环视(偏航/俯仰)
///   * 双指缩放 = 视场角
///   * 常规手势(左右进退、上下亮度/音量、上下滑全屏、双指缩放画面)全部让位
/// 同时提供屏幕按钮兜底(长按可连续转动), 以及实时视角读数,
/// 方便确认操作是否生效。方案参考 PiliPlus#364「切换操作模式」。
class VrControlLayer extends StatefulWidget {
  const VrControlLayer({
    super.key,
    required this.controller,
    required this.width,
    required this.height,
    required this.child,
  });

  final PlPlayerController controller;
  final double width;
  final double height;
  final Widget child;

  @override
  State<VrControlLayer> createState() => _VrControlLayerState();
}

class _VrControlLayerState extends State<VrControlLayer> {
  /// 双指缩放开始时的视场角, 缩放按该基准做绝对映射(避免累积漂移)
  double _fovBase = VrViewState.kVrDefaultFov;

  PlPlayerController get _c => widget.controller;

  void _onScaleStart(ScaleStartDetails details) {
    _fovBase = _c.vrView.value.fov;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    if (details.pointerCount > 1) {
      if (details.scale > 0) {
        _c.setVrFov(_fovBase / details.scale);
      }
      return;
    }
    _c.onVrLook(
      details.focalPointDelta.dx,
      details.focalPointDelta.dy,
      width: widget.width,
      height: widget.height,
    );
  }

  void _onScaleEnd(ScaleEndDetails details) {
    // 手势结束强制落一次, 保证最终视角与手指位置一致
    _c.applyVrView(force: true);
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _c.controls = !_c.showControls.value,
          onScaleStart: _onScaleStart,
          onScaleUpdate: _onScaleUpdate,
          onScaleEnd: _onScaleEnd,
          child: widget.child,
        ),
        // 顶部: 视角读数 + 退出控制模式
        Align(
          alignment: Alignment.topCenter,
          child: Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Obx(() {
              final view = _c.vrView.value;
              final error = _c.vrError.value;
              return Column(
                mainAxisSize: MainAxisSize.min,
                spacing: 6,
                children: [
                  _Chip(
                    onTap: () => _c.setVrControlMode(false),
                    icon: Icons.gesture_outlined,
                    label:
                        '偏航 ${view.yaw.toStringAsFixed(1)}°  '
                        '俯仰 ${view.pitch.toStringAsFixed(1)}°  '
                        '视场 ${view.fov.toStringAsFixed(0)}°  ·  点按退出VR操作',
                  ),
                  // 着色器没生效时把原因摊开, 不要让用户面对"操作没反应"
                  if (error != null)
                    _Chip(
                      icon: Icons.error_outline,
                      label: error,
                      danger: true,
                    ),
                ],
              );
            }),
          ),
        ),
        // 左侧: 方向步进
        Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.only(left: 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _VrStepButton(
                  icon: Icons.keyboard_arrow_up,
                  tooltip: '向上',
                  onStep: () => _c.vrStep(dpitch: PlPlayerController.vrStepDeg),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _VrStepButton(
                      icon: Icons.keyboard_arrow_left,
                      tooltip: '向左',
                      onStep: () =>
                          _c.vrStep(dyaw: -PlPlayerController.vrStepDeg),
                    ),
                    _VrStepButton(
                      icon: Icons.keyboard_arrow_right,
                      tooltip: '向右',
                      onStep: () => _c.vrStep(dyaw: PlPlayerController.vrStepDeg),
                    ),
                  ],
                ),
                _VrStepButton(
                  icon: Icons.keyboard_arrow_down,
                  tooltip: '向下',
                  onStep: () => _c.vrStep(dpitch: -PlPlayerController.vrStepDeg),
                ),
              ],
            ),
          ),
        ),
        // 右侧: 视场角 / 重置 / 眼位
        Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: const EdgeInsets.only(right: 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _VrStepButton(
                  icon: Icons.zoom_in,
                  tooltip: '放大(视场角变小)',
                  onStep: () => _c.vrStep(dfov: -PlPlayerController.vrFovStep),
                ),
                _VrStepButton(
                  icon: Icons.zoom_out,
                  tooltip: '缩小(视场角变大)',
                  onStep: () => _c.vrStep(dfov: PlPlayerController.vrFovStep),
                ),
                _VrStepButton(
                  icon: Icons.center_focus_strong_outlined,
                  tooltip: '视角摆正',
                  repeat: false,
                  onStep: _c.resetVrView,
                ),
                Obx(
                  () => _c.vrProjection.value.isStereo
                      ? _VrStepButton(
                          icon: Icons.visibility_outlined,
                          tooltip: '切换眼位',
                          repeat: false,
                          onStep: () => _c.setVrEye(
                            _c.vrEye.value == VrEye.left
                                ? VrEye.right
                                : VrEye.left,
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.icon,
    this.onTap,
    this.danger = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        borderRadius: const BorderRadius.all(Radius.circular(20)),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 420),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: danger ? 0.75 : 0.55),
            borderRadius: const BorderRadius.all(Radius.circular(20)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            spacing: 6,
            children: [
              Icon(
                icon,
                size: 15,
                color: danger ? Colors.redAccent : Colors.white,
              ),
              Flexible(
                child: Text(
                  label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 支持"点一下走一步、按住连续走"的按钮
class _VrStepButton extends StatefulWidget {
  const _VrStepButton({
    required this.icon,
    required this.tooltip,
    required this.onStep,
    this.repeat = true,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onStep;
  final bool repeat;

  @override
  State<_VrStepButton> createState() => _VrStepButtonState();
}

class _VrStepButtonState extends State<_VrStepButton> {
  Timer? _delay;
  Timer? _repeat;

  void _start() {
    widget.onStep();
    if (!widget.repeat) {
      return;
    }
    _delay = Timer(const Duration(milliseconds: 400), () {
      _repeat = Timer.periodic(
        const Duration(milliseconds: 110),
        (_) => widget.onStep(),
      );
    });
  }

  void _stop() {
    _delay?.cancel();
    _repeat?.cancel();
    _delay = null;
    _repeat = null;
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => _start(),
        onTapUp: (_) => _stop(),
        onTapCancel: _stop,
        child: Container(
          margin: const EdgeInsets.all(3),
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.45),
            shape: BoxShape.circle,
          ),
          child: Icon(widget.icon, size: 22, color: Colors.white),
        ),
      ),
    );
  }
}
