import 'dart:math' as math;

/// VR 陀螺仪的纯数学部分: 姿态判定 + 角速度到"偏航/俯仰"增量的映射。
///
/// 不依赖 Flutter/传感器插件, 便于单元测试。参考 xl_player(Cardboard
/// HeadTracker)的头追踪思路, 但只用陀螺仪积分 + 重力定姿态:
///   * 加速度计(重力)判断手机当前的持握姿态(竖屏/横屏左/横屏右/倒置),
///     因为安卓陀螺仪的 x/y/z 轴固定在**设备**坐标系上, 不随旋转变化;
///   * 陀螺仪角速度按姿态映射到世界坐标系的"绕竖直轴(偏航)/绕水平轴
///     (俯仰)"分量, 积分成角度增量。
/// 符号约定与 `VrViewState` 一致: **yaw+ = 向右看, pitch+ = 向上看**。
abstract final class VrGyroMath {
  /// 持握姿态
  static const int posePortrait = 0;
  static const int poseLandscapeTopLeft = 1; // 顶部朝左(Android ROTATION_90)
  static const int posePortraitUpsideDown = 2;
  static const int poseLandscapeTopRight = 3; // 顶部朝右(ROTATION_270)

  static const double _rad2deg = 180.0 / math.pi;

  /// 静止时陀螺仪的零偏死区(rad/s), 低于它视为不动, 抑制漂移
  static const double deadzone = 0.03;

  /// 从加速度计读数(m/s², 设备坐标系, 静止时读数是"反作用力"≈ +9.8 沿
  /// 屏幕上方)判断持握姿态。接近水平放置(重力几乎全在 z 轴)时保持上一个
  /// 姿态; 两个水平分量接近时也保持, 避免临界抖动导致操控方向翻转。
  static int poseFromAccelerometer(
    double ax,
    double ay,
    double az,
    int lastPose,
  ) {
    final flat = az.abs() > 7.0 && ax.abs() < 3.0 && ay.abs() < 3.0;
    if (flat) {
      return lastPose;
    }
    // 迟滞: 主导轴要明显胜出才切换
    if ((ax.abs() - ay.abs()).abs() < 1.0) {
      return lastPose;
    }
    if (ax.abs() > ay.abs()) {
      // 横屏: 顶部朝左时 +x 指向天空(读数 +9.8)
      return ax > 0 ? poseLandscapeTopLeft : poseLandscapeTopRight;
    }
    return ay > 0 ? posePortrait : posePortraitUpsideDown;
  }

  /// 把一次陀螺仪采样(rad/s, 设备坐标系)换算成视角增量(度)。
  ///
  /// 推导: 世界系 +X=用户右方, +Y=竖直向上, +Z=指向用户; 视线方向为 -Z。
  ///   * 向右看 = 视线转向 +X = 绕 +Y 的**负**向旋转 -> dyaw = -ω_Yw
  ///   * 向上看 = 视线转向 +Y = 绕 +X 的正向旋转     -> dpitch = +ω_Xw
  /// 各姿态下设备轴到世界轴的映射:
  ///   竖屏:        +xd=+Xw, +yd=+Yw  -> dyaw=-wy, dpitch=+wx
  ///   横屏(顶左):  +xd=+Yw, +yd=-Xw  -> dyaw=-wx, dpitch=-wy
  ///   竖屏倒置:    +xd=-Xw, +yd=-Yw  -> dyaw=+wy, dpitch=-wx
  ///   横屏(顶右):  +xd=-Yw, +yd=+Xw  -> dyaw=+wx, dpitch=+wy
  static ({double dyawDeg, double dpitchDeg}) lookDelta({
    required double wx,
    required double wy,
    required double wz,
    required int pose,
    required double dtSeconds,
  }) {
    if (dtSeconds <= 0 || dtSeconds > 0.25 || !wx.isFinite || !wy.isFinite) {
      return (dyawDeg: 0, dpitchDeg: 0);
    }
    final x = _gated(wx);
    final y = _gated(wy);
    final (double yawRad, double pitchRad) = switch (pose) {
      poseLandscapeTopLeft => (-x, -y),
      posePortraitUpsideDown => (y, -x),
      poseLandscapeTopRight => (x, y),
      _ => (-y, x), // 竖屏
    };
    return (
      dyawDeg: yawRad * dtSeconds * _rad2deg,
      dpitchDeg: pitchRad * dtSeconds * _rad2deg,
    );
  }

  static double _gated(double rate) =>
      rate.abs() < deadzone ? 0.0 : rate;
}
