import 'dart:async';
import 'dart:io' show Platform;

import 'package:PiliPlus/plugin/pl_player/models/vr_projection.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

/// 自研 VR 播放器的 Dart 侧控制器。
///
/// 对应 Android 端 `com.example.piliplus.vr.*`：
/// `MediaCodec 硬解 -> SurfaceTexture(OES) -> 自己的 GLES2 程序 -> Flutter Texture`，
/// yaw/pitch/fov/眼位/覆盖角全部是 **uniform**，每帧直接改，
/// 不重编译着色器、不重建渲染管线 —— 这是 mpv `vo=gpu` 用户着色器做不到的
/// （它只能把参数烘焙进源码，详见 docs/piliplayer.md 9.1）。
///
/// 视角状态以 native 为准：这边只发**增量指令**（[lookBy] / [setFov] /
/// [resetView]），native 每帧把头追增量叠上去，再按 10Hz 把读数回报过来显示。
/// 头追不经过 Flutter 往返，所以能逐帧跟手。
class VrNativePlayerController extends GetxController {
  VrNativePlayerController({
    required VrProjection initialProjection,
    required VrEye initialEye,
    required double initialFov,
    required bool initialGyro,
  }) : projection = Rx<VrProjection>(initialProjection),
       eye = Rx<VrEye>(initialEye),
       gyro = RxBool(initialGyro),
       _fov = initialFov;

  static const MethodChannel _channel = MethodChannel('piliplus/vr_player');

  /// 只有安卓端实现了这套渲染管线
  static bool get isSupported => Platform.isAndroid;

  final Rx<VrProjection> projection;
  final Rx<VrEye> eye;
  final RxBool gyro;

  double _fov;

  /// Flutter `Texture` 用的 id，[open] 成功后才有
  int? get textureId => _textureId;
  int? _textureId;

  final RxBool ready = RxBool(false);
  final RxBool playing = RxBool(true);
  final RxBool buffering = RxBool(false);
  final RxBool hasAudio = RxBool(true);
  final RxBool ended = RxBool(false);
  final Rx<Duration> position = Rx<Duration>(Duration.zero);
  final Rx<Duration> duration = Rx<Duration>(Duration.zero);
  final RxnString error = RxnString();

  /// native 回报的诊断信息（渲染目标尺寸 / 解码帧数 / 渲染帧数 / GL 错误 …）。
  /// 排查"画面是纯色"这类只有真机能复现的问题时，一行字比 logcat 好用。
  final RxString debug = RxString('');

  /// 诊断模式：跳过球面投影，把解码帧原样贴出来。
  /// 有画面 => 问题在投影；仍是纯色 => 问题在解码/纹理链路。
  final RxBool passthrough = RxBool(false);

  /// 片源 v 方向是否额外翻转。
  /// **默认关**：渲染层换成移植的 xl_player 之后，贴图坐标直接用
  /// `SurfaceTexture.getTransformMatrix()` 的结果（上游 `bind_texture_oes` 就是这么做的），
  /// 方向本来就对。手写渲染器时代默认是 true —— 那是我们自己算 uv 才需要的补偿。
  /// 各机型的 transform matrix 偶有差异，所以保留成可实时切换的开关。
  final RxBool flipV = RxBool(false);

  /// 手动拖动的轴向符号（诊断用）。真机上如果拖动方向反了，当场切一下就能确认，
  /// 不必为这个再出一版包。
  final RxDouble axisYawSign = RxDouble(1);
  final RxDouble axisPitchSign = RxDouble(1);

  // 视角读数（native 回报，10Hz）
  final RxDouble yaw = RxDouble(0);
  final RxDouble pitch = RxDouble(0);
  final RxDouble fov = RxDouble(90);

  bool _closed = false;

  /// 打开后 10 秒还没有任何画面就明确报错(附上 native 的诊断信息)。
  /// 否则用户只会看到一个纯色/蓝屏, 完全不知道卡在哪一环。
  Timer? _firstFrameWatchdog;

  /// 打开并开始播放。失败返回 false（原因在 [error]）。
  Future<bool> open({
    required String uri,
    Map<String, String>? headers,
    Duration start = Duration.zero,
  }) async {
    if (!isSupported) {
      error.value = '当前平台不支持自研 VR 播放器（仅安卓）';
      return false;
    }
    _channel.setMethodCallHandler(_onNativeCall);
    try {
      final id = await _channel.invokeMethod<int>('create');
      if (id == null) {
        error.value = '创建渲染面失败';
        return false;
      }
      _textureId = id;
      await _channel.invokeMethod<bool>('open', {
        'uri': uri,
        'headers': headers,
        'startPositionUs': start.inMicroseconds,
        'projection': projection.value.name,
        'eye': eye.value.name,
        'fov': _fov,
      });
      await _channel.invokeMethod<bool>('setGyro', {'enabled': gyro.value});
      // native 每次 create 都是全新的一份状态，把诊断开关按 Dart 侧的现值补推一次，
      // 否则重开一个视频后 UI 显示"开"而 native 其实是"关"。
      await _invoke('setFlipV', {'enabled': flipV.value});
      await _invoke('setPassthrough', {'enabled': passthrough.value});
      await _invoke('setAxisSign', {
        'yaw': axisYawSign.value,
        'pitch': axisPitchSign.value,
      });
      ready.value = true;
      _firstFrameWatchdog?.cancel();
      _firstFrameWatchdog = Timer(const Duration(seconds: 10), () {
        if (_closed) {
          return;
        }
        final info = debug.value;
        // 移植 xl_player 后 debugInfo 的字段变了：native 每画一帧 frames++,
        // 一帧都没画说明 EGL/纹理/解码其中一环没通。
        if (RegExp(r'frames=0(\s|$)').hasMatch(info)) {
          error.value = '10 秒内没有解出任何画面。\n$info';
        }
      });
      return true;
    } on MissingPluginException {
      error.value = '这个安装包没有自研 VR 播放器（native 桥未注册）';
      return false;
    } on PlatformException catch (e) {
      error.value = '打开失败: ${e.message}';
      return false;
    } catch (e) {
      error.value = '打开失败: $e';
      return false;
    }
  }

  Future<void> _onNativeCall(MethodCall call) async {
    if (_closed) {
      return;
    }
    final args = call.arguments;
    switch (call.method) {
      case 'prepared':
        if (args is Map) {
          final us = (args['durationUs'] as num?)?.toInt() ?? 0;
          duration.value = Duration(microseconds: us);
          hasAudio.value = args['hasAudio'] != false;
        }
      case 'view':
        if (args is Map) {
          yaw.value = (args['yaw'] as num?)?.toDouble() ?? yaw.value;
          pitch.value = (args['pitch'] as num?)?.toDouble() ?? pitch.value;
          fov.value = (args['fov'] as num?)?.toDouble() ?? fov.value;
          final us = (args['positionUs'] as num?)?.toInt();
          if (us != null) {
            position.value = Duration(microseconds: us);
          }
          if (args['debug'] case final String d) {
            debug.value = d;
          }
        }
      case 'buffering':
        buffering.value = args is Map && args['value'] == true;
      case 'ended':
        ended.value = true;
        playing.value = false;
      case 'error':
        error.value = args is Map ? '${args['message']}' : '$args';
    }
  }

  // ==================== 播放控制 ====================

  void play() {
    _invoke('play');
    playing.value = true;
    ended.value = false;
  }

  void pause() {
    _invoke('pause');
    playing.value = false;
  }

  void toggle() => playing.value ? pause() : play();

  void seek(Duration to) {
    position.value = to;
    _invoke('seekTo', {'us': to.inMicroseconds});
  }

  /// 相对跳转（进度条两侧的快进/快退按钮）
  void seekBy(Duration delta) {
    final total = duration.value;
    var next = position.value + delta;
    if (next < Duration.zero) {
      next = Duration.zero;
    }
    if (total > Duration.zero && next > total) {
      next = total;
    }
    seek(next);
  }

  void setSpeed(double speed) => _invoke('setSpeed', {'speed': speed});

  /// 告诉 native 渲染目标有多大（**设备像素**）。
  ///
  /// Flutter 的 `TextureRegistry.createSurfaceTexture()` 不会替插件设
  /// SurfaceTexture 的 defaultBufferSize，不设就是 0x0，EGL 交换出来的缓冲
  /// 只有一个像素，Flutter 把它拉伸铺满全屏 —— 画面就成了**一个纯色**。
  void setRenderSize(int width, int height) {
    if (width < 2 || height < 2) {
      return;
    }
    _invoke('setRenderSize', {'width': width, 'height': height});
  }

  Future<void> setPassthrough(bool value) async {
    passthrough.value = value;
    await _invoke('setPassthrough', {'enabled': value});
  }

  Future<void> setFlipV(bool value) async {
    flipV.value = value;
    await _invoke('setFlipV', {'enabled': value});
  }

  Future<void> setAxisSign({double? yaw, double? pitch}) async {
    if (yaw != null) axisYawSign.value = yaw;
    if (pitch != null) axisPitchSign.value = pitch;
    await _invoke('setAxisSign', {
      'yaw': axisYawSign.value,
      'pitch': axisPitchSign.value,
    });
  }

  // ==================== 视角 ====================

  /// 拖拽环视。dx/dy 为像素位移，方向约定与 mpv 版一致：
  /// 手指右滑 -> 画面右移 -> 视角左转；手指下滑 -> 看到更高处。
  void lookByPixels(
    double dx,
    double dy, {
    required double width,
    required double height,
  }) {
    final scale = fov.value * 1.5;
    lookBy(
      -dx * scale / (width < 1 ? 1 : width),
      dy * scale / (height < 1 ? 1 : height),
    );
  }

  void lookBy(double dyaw, double dpitch) =>
      _invoke('lookBy', {'dyaw': dyaw, 'dpitch': dpitch});

  void setFov(double value) {
    _fov = value.clamp(VrViewState.minFov, VrViewState.maxFov);
    _invoke('setFov', {'fov': _fov});
  }

  /// 双指缩放：factor > 1 表示放大（视场角变小）
  void zoomBy(double factor) {
    if (factor <= 0) {
      return;
    }
    setFov(fov.value / factor);
  }

  void resetView() => _invoke('resetView');

  Future<void> setProjection(VrProjection value) async {
    if (!value.enabled) {
      return;
    }
    projection.value = value;
    await _invoke('setProjection', {'mode': value.name});
  }

  Future<void> setEye(VrEye value) async {
    eye.value = value;
    await _invoke('setEye', {'eye': value.name});
  }

  Future<void> setGyro(bool value) async {
    gyro.value = value;
    await _invoke('setGyro', {'enabled': value});
  }

  Future<void> _invoke(String method, [Map<String, Object?>? args]) async {
    try {
      await _channel.invokeMethod<bool>(method, args);
    } catch (_) {
      // 页面正在销毁时 native 侧可能已经释放, 这里不必再报错打扰用户
    }
  }

  @override
  void onClose() {
    _closed = true;
    _firstFrameWatchdog?.cancel();
    _invoke('release');
    try {
      _channel.setMethodCallHandler(null);
    } catch (_) {}
    super.onClose();
  }
}
