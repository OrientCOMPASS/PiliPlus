import 'package:PiliPlus/models/common/enum_with_label.dart';

/// VR / 全景视频的片源布局。
///
/// 全景片源以等距柱状投影(equirectangular)存储, 播放时由 GPU 着色器把片源
/// 重投影为普通视角(rectilinear), 见 `lib/plugin/pl_player/utils/vr_shader.dart`。
enum VrProjection with EnumWithLabel {
  off('关闭'),
  equirect360('等距柱状 360°'),
  equirect180('等距柱状 180°'),
  sbs360('左右格式 360°'),
  tb360('上下格式 360°'),
  sbs180('左右格式 180°'),
  tb180('上下格式 180°'),
  ;

  @override
  final String label;
  const VrProjection(this.label);

  bool get enabled => this != VrProjection.off;

  /// 双目(3D)片源: 渲染时只取其中一只眼睛的画面
  bool get isStereo =>
      this == VrProjection.sbs360 ||
      this == VrProjection.tb360 ||
      this == VrProjection.sbs180 ||
      this == VrProjection.tb180;

  /// 左右格式(side by side): 两只眼睛的画面左右排列
  bool get isSideBySide =>
      this == VrProjection.sbs360 || this == VrProjection.sbs180;

  /// 水平覆盖角度, 360° 片源可以无限水平旋转, 180° 片源需要在边界处收敛
  double get coverageH =>
      this == VrProjection.equirect180 ||
          this == VrProjection.sbs180 ||
          this == VrProjection.tb180
      ? 180.0
      : 360.0;

  /// 垂直覆盖角度, 等距柱状投影固定为 180°
  double get coverageV => 180.0;

  /// 偏航角(yaw)的可活动范围, 单位: 度
  ({double min, double max}) yawRange(double fov) {
    if (coverageH >= 360.0) {
      return (min: -180.0, max: 180.0);
    }
    // 180° 片源: 视口不能越过片源边界, 否则会出现黑边
    final limit = (coverageH - fov) / 2;
    return (min: -limit, max: limit);
  }

  /// 根据文件名猜测片源布局。
  ///
  /// 只认明确的关键词, 并且对 `360`/`180`/`vr`/`3d`/`tb` 这类容易误伤的短词
  /// 做词边界匹配(否则清晰度 `360p`、`1080p` 会被误判成全景片源)。
  /// 宽高比不作为判据: 2:1 也可能是普通宽银幕视频。
  static VrProjection detectFromName(String name) {
    final n = name.toLowerCase();
    // 字母边界匹配, 允许数字紧邻(如 `360vr`)
    bool word(String key) => RegExp('(^|[^a-z])$key([^a-z]|\$)').hasMatch(n);
    // 数字关键词: 排除 `360p` / `1080p` 这类清晰度写法
    bool numberWord(String key) =>
        RegExp('(^|[^0-9])$key([^0-9p]|\$)').hasMatch(n);
    bool has(List<String> keys) => keys.any(n.contains);

    final is180 = numberWord('180');
    final is360 = numberWord('360');
    final isVr = word('vr') || has(['全景']);

    final sbs =
        word('sbs') ||
        has(['左右格式', '左右3d', '3d左右', 'lr3d', '3dlr', '左右']);
    final tb =
        word('tb') ||
        word('ou') ||
        has(['over-under', 'over_under', '上下格式', '上下3d', '3d上下', '上下']);

    final pano =
        isVr ||
        is360 ||
        is180 ||
        word('pano') ||
        has(['equirect', 'equi-angular', 'panoram', 'spherical']);
    // 只有 `3d` 字样无法判断片源布局, 不乱猜
    if (!pano && !sbs && !tb) {
      return VrProjection.off;
    }

    // tb 与 sbs 同时出现时以 sbs 为准(更常见的命名)
    if (tb && !sbs) {
      return is180 && !is360 ? VrProjection.tb180 : VrProjection.tb360;
    }
    if (sbs) {
      return is180 && !is360 ? VrProjection.sbs180 : VrProjection.sbs360;
    }
    return is180 && !is360
        ? VrProjection.equirect180
        : VrProjection.equirect360;
  }
}

/// 双目片源要渲染哪一只眼睛(手机端为单屏显示, 只取一只)
enum VrEye with EnumWithLabel {
  left('左眼'),
  right('右眼'),
  ;

  @override
  final String label;
  const VrEye(this.label);
}

/// 视角参数。yaw/pitch 单位为度, fov 为水平视场角(度)。
class VrViewState {
  /// 默认水平视场角: 手机竖屏/横屏下接近人眼舒适范围
  static const double kVrDefaultFov = 90.0;
  static const double minFov = 25.0;
  static const double maxFov = 120.0;
  static const double maxPitch = 89.0;

  const VrViewState({
    this.yaw = 0,
    this.pitch = 0,
    this.fov = VrViewState.kVrDefaultFov,
  });

  final double yaw;
  final double pitch;
  final double fov;

  /// 量化: 步长由 [VrQuantizer](utils/vr_shader.dart) 按变体用量自适应给出,
  /// 数值量化后没变化就不必重新下发着色器。
  static double quantize(double value, double step) =>
      (value / step).roundToDouble() * step;

  VrViewState clamped(VrProjection projection) {
    final fov = this.fov.clamp(minFov, maxFov);
    final range = projection.yawRange(fov);
    return VrViewState(
      // 360° 片源: 偏航角回绕, 避免数值无限增长
      yaw: projection.coverageH >= 360.0
          ? _wrap180(yaw)
          : yaw.clamp(range.min, range.max),
      pitch: pitch.clamp(-maxPitch, maxPitch),
      fov: fov,
    );
  }

  static double _wrap180(double value) {
    var v = value % 360.0;
    if (v > 180.0) v -= 360.0;
    if (v < -180.0) v += 360.0;
    return v;
  }

  /// 与另一个状态在量化后是否等价(等价则无需重载着色器)
  bool sameRenderState(
    VrViewState other, {
    required double angleStep,
    required double fovStep,
  }) =>
      quantize(yaw, angleStep) == quantize(other.yaw, angleStep) &&
      quantize(pitch, angleStep) == quantize(other.pitch, angleStep) &&
      quantize(fov, fovStep) == quantize(other.fov, fovStep);

  VrViewState copyWith({double? yaw, double? pitch, double? fov}) => VrViewState(
    yaw: yaw ?? this.yaw,
    pitch: pitch ?? this.pitch,
    fov: fov ?? this.fov,
  );

  @override
  String toString() =>
      'yaw=${yaw.toStringAsFixed(1)} pitch=${pitch.toStringAsFixed(1)} '
      'fov=${fov.toStringAsFixed(1)}';
}
