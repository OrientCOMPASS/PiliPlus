import 'dart:async';

import 'package:PiliPlus/plugin/pl_player/utils/vr_gyro_math.dart';
import 'package:sensors_plus/sensors_plus.dart';

/// VR 陀螺仪视角追踪(参考 xl_player 的头部追踪, 显式开关)。
///
/// 用 `sensors_plus` 的陀螺仪流积分出视角增量, 加速度计流判定持握姿态
/// (纯数学在 [VrGyroMath], 可单测)。刻意不做卡尔曼/互补滤波:
/// 视角只需要短周期内的相对转动, 死区 + 低通已能压住静止漂移,
/// 而重滤波会引入可感知的延迟(头动跟手性是 VR 体验的第一要素)。
class VrGyroTracker {
  StreamSubscription<GyroscopeEvent>? _gyroSub;
  StreamSubscription<AccelerometerEvent>? _accelSub;

  int _pose = VrGyroMath.poseLandscapeTopLeft; // VR 场景以横屏为主
  DateTime? _lastSample;

  /// 陀螺仪低通滤波后的角速度(设备坐标系, rad/s)
  double _fx = 0, _fy = 0;
  static const double _smooth = 0.55; // 新采样的权重

  bool get running => _gyroSub != null;

  /// 开始追踪。[onLook] 在 UI isolate 上回调, 参数为(偏航增量, 俯仰增量)度,
  /// 符号与 `VrViewState` 一致(yaw+ 向右看, pitch+ 向上看)。
  void start({required void Function(double dyawDeg, double dpitchDeg) onLook}) {
    stop();
    _lastSample = null;
    _fx = 0;
    _fy = 0;
    _gyroSub = gyroscopeEventStream(
      samplingPeriod: const Duration(milliseconds: 20),
    ).listen(
      (event) {
        final now = DateTime.now();
        final last = _lastSample;
        _lastSample = now;
        if (last == null) {
          return;
        }
        final dt = now.difference(last).inMicroseconds / 1e6;
        // 低通滤波压制陀螺仪噪声
        _fx = _fx + (event.x - _fx) * _smooth;
        _fy = _fy + (event.y - _fy) * _smooth;
        final delta = VrGyroMath.lookDelta(
          wx: _fx,
          wy: _fy,
          wz: event.z,
          pose: _pose,
          dtSeconds: dt,
        );
        if (delta.dyawDeg != 0 || delta.dpitchDeg != 0) {
          onLook(delta.dyawDeg, delta.dpitchDeg);
        }
      },
      onError: (_) {},
      cancelOnError: false,
    );
    // 姿态判定不需要高频
    _accelSub = accelerometerEventStream(
      samplingPeriod: const Duration(milliseconds: 250),
    ).listen(
      (event) {
        _pose = VrGyroMath.poseFromAccelerometer(
          event.x,
          event.y,
          event.z,
          _pose,
        );
      },
      onError: (_) {},
      cancelOnError: false,
    );
  }

  void stop() {
    _gyroSub?.cancel();
    _accelSub?.cancel();
    _gyroSub = null;
    _accelSub = null;
  }
}
