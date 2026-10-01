import 'dart:async';

import 'package:flutter/services.dart';
import 'package:get/get.dart';

/// 一条 VLC 轨道(音轨/字幕轨/视频轨)
class VlcTrack {
  const VlcTrack({required this.id, required this.name});

  final int id;
  final String name;

  String get label => name.isNotEmpty ? name : '轨道 $id';
}

/// 视频画面尺寸(用于 Texture 的宽高比)
class VlcVideoSize {
  const VlcVideoSize({
    required this.width,
    required this.height,
    this.sarNum = 1,
    this.sarDen = 1,
  });

  static const VlcVideoSize none = VlcVideoSize(width: 16, height: 9);

  final int width;
  final int height;
  final int sarNum;
  final int sarDen;

  double get aspect =>
      height <= 0
          ? 16 / 9
          : (width * (sarNum <= 0 ? 1 : sarNum)) /
                (height * (sarDen <= 0 ? 1 : sarDen));
}

/// VLC 播放器的 Dart 控制器(GetxController, 单页面单实例)。
///
/// 对应 Kotlin 侧 `VlcPlayerBridge`(MethodChannel `piliplus/vlc_player`)。
/// 画面经 SurfaceTexture → Flutter `Texture` 合成(与 media_kit/mpv 相同的
/// 外部纹理模式), 控件层照常叠在上面; 360° 片源由 libvlc 原生渲染,
/// 视角(拖拽/陀螺仪)在 Kotlin 侧逐帧 `updateViewpoint`, 不经过 Dart 往返。
class VlcPlayerController extends GetxController {
  static const MethodChannel _ch = MethodChannel('piliplus/vlc_player');

  /// Flutter Texture 的 id, open 成功后非 null
  int? textureId;

  final RxBool ready = false.obs;
  final RxBool playing = false.obs;
  final RxBool seekable = true.obs;
  final RxBool buffering = false.obs;
  final RxDouble bufferingPercent = 0.0.obs;
  final Rx<Duration> position = Duration.zero.obs;
  final Rx<Duration> length = Duration.zero.obs;
  final RxnString error = RxnString();

  /// 是否 360°/全景片源(libvlc 解析轨道 projection 元数据得出)
  final RxBool is360 = false.obs;
  final RxBool gyroOn = false.obs;
  final RxBool gyroUnavailable = false.obs;
  final Rx<VlcVideoSize> videoSize = VlcVideoSize.none.obs;

  final RxList<VlcTrack> audioTracks = <VlcTrack>[].obs;
  final RxList<VlcTrack> spuTracks = <VlcTrack>[].obs;
  final RxInt curAudio = (-1).obs;
  final RxInt curSpu = (-1).obs;

  final RxDouble rate = 1.0.obs;

  /// 360° 手动视角读数(度; 仅手动分量, 头追由 native 叠加)
  final RxDouble vpYaw = 0.0.obs;
  final RxDouble vpPitch = 0.0.obs;
  final RxDouble vpFov = 80.0.obs;

  bool _handlerBound = false;
  bool _closed = false;

  void _bindHandler() {
    if (_handlerBound) {
      return;
    }
    _handlerBound = true;
    _ch.setMethodCallHandler((call) async {
      if (_closed) {
        return null;
      }
      final args = call.arguments;
      switch (call.method) {
        case 'onPrepared':
          if (args is Map) {
            final len = (args['lengthMs'] as num?)?.toInt() ?? 0;
            if (len > 0) {
              length.value = Duration(milliseconds: len);
            }
            is360.value = args['is360'] as bool? ?? false;
          }
          ready.value = true;
        case 'onPosition':
          if (args is Map) {
            position.value = Duration(
              milliseconds: (args['timeMs'] as num?)?.toInt() ?? 0,
            );
            final len = (args['lengthMs'] as num?)?.toInt() ?? 0;
            if (len > 0 && len != length.value.inMilliseconds) {
              length.value = Duration(milliseconds: len);
            }
          }
        case 'onPlaying':
          playing.value = true;
          buffering.value = false;
        case 'onPaused':
          playing.value = false;
        case 'onStopped':
          playing.value = false;
        case 'onEnded':
          playing.value = false;
          onEnded?.call();
        case 'onError':
          error.value = (args is Map ? args['message'] as String? : null) ??
              'VLC 播放失败';
          playing.value = false;
          buffering.value = false;
        case 'onBuffering':
          final pct = (args is Map ? (args['percent'] as num?)?.toDouble() : null) ??
              0.0;
          bufferingPercent.value = pct;
          // 100% 即缓冲完成; <100 且未在播 → 转圈
          buffering.value = pct < 100.0 && !playing.value;
        case 'onVout':
          // 有视频输出即认为就绪(纯音频源不会触发)
          ready.value = true;
        case 'onVideoLayout':
          if (args is Map) {
            videoSize.value = VlcVideoSize(
              width: (args['visibleWidth'] as num?)?.toInt() ?? 16,
              height: (args['visibleHeight'] as num?)?.toInt() ?? 9,
              sarNum: (args['sarNum'] as num?)?.toInt() ?? 1,
              sarDen: (args['sarDen'] as num?)?.toInt() ?? 1,
            );
          }
        case 'onTracks':
          if (args is Map) {
            audioTracks.assignAll(_tracks(args['audio']));
            spuTracks.assignAll(_tracks(args['spu']));
            curAudio.value = (args['curAudio'] as num?)?.toInt() ?? -1;
            curSpu.value = (args['curSpu'] as num?)?.toInt() ?? -1;
          }
        case 'onGyroUnavailable':
          gyroUnavailable.value = true;
          gyroOn.value = false;
      }
      return null;
    });
  }

  static List<VlcTrack> _tracks(dynamic raw) => [
    if (raw is List)
      for (final e in raw)
        if (e is Map)
          VlcTrack(
            id: (e['id'] as num?)?.toInt() ?? 0,
            name: e['name'] as String? ?? '',
          ),
  ];

  /// 播完回调(播放页用来走列表循环/下一个)
  void Function()? onEnded;

  /// 打开媒体并起播。[uri] 为 libvlc 可识别的地址(file:///…、smb://…、http://…)。
  /// 返回 Flutter Texture id; 失败返回 null(错误经 [error] 暴露)。
  Future<int?> open(
    String uri, {
    Duration start = Duration.zero,
    double rate = 1.0,
  }) async {
    _bindHandler();
    ready.value = false;
    error.value = null;
    is360.value = false;
    buffering.value = true;
    bufferingPercent.value = 0;
    try {
      final id = await _ch.invokeMethod<int>('open', {
        'uri': uri,
        'startMs': start.inMilliseconds,
        'rate': rate,
      });
      textureId = id;
      this.rate.value = rate;
      return id;
    } catch (e) {
      error.value = 'VLC 打开失败: $e';
      return null;
    }
  }

  Future<void> play() => _invoke('play');
  Future<void> pause() => _invoke('pause');
  Future<void> toggle() =>
      playing.value ? _invoke('pause') : _invoke('play');

  Future<void> seekTo(Duration pos) async {
    position.value = pos; // 乐观更新, 事件流随后校正
    await _invoke('seekTo', {'ms': pos.inMilliseconds});
  }

  Future<void> seekBy(Duration delta) => seekTo(position.value + delta);

  Future<void> setRate(double value) async {
    rate.value = value;
    await _invoke('setRate', {'rate': value});
  }

  Future<void> setAudioTrack(int id) => _invoke('setAudioTrack', {'id': id});
  Future<void> setSpuTrack(int id) => _invoke('setSpuTrack', {'id': id});

  /// 加载外挂字幕文件(本机路径或 URL); libvlc 还会自动探测同名字幕
  Future<void> addSubtitle(String path) =>
      _invoke('addSubtitle', {'path': path});

  /// 画面缩放: bestFit / fill / fitScreen
  Future<void> setScale(String mode) => _invoke('setScale', {'mode': mode});

  /// 强制宽高比("" = 跟随片源)
  Future<void> setAspect(String aspect) =>
      _invoke('setAspect', {'aspect': aspect});

  // ---------------- 360° ----------------

  /// 手动环视增量(度)。native 会与头追姿态叠加后逐帧下发。
  Future<void> lookBy({double dyaw = 0, double dpitch = 0}) async {
    try {
      final res = await _ch.invokeMethod<Map<dynamic, dynamic>>('lookBy', {
        'dyaw': dyaw,
        'dpitch': dpitch,
      });
      if (res != null) {
        vpYaw.value = (res['yaw'] as num?)?.toDouble() ?? vpYaw.value;
        vpPitch.value = (res['pitch'] as num?)?.toDouble() ?? vpPitch.value;
      }
    } catch (_) {}
  }

  Future<void> setFov(double fov) async {
    try {
      final res = await _ch.invokeMethod<Map<dynamic, dynamic>>(
        'setFov',
        {'fov': fov},
      );
      vpFov.value = (res?['fov'] as num?)?.toDouble() ?? fov;
    } catch (_) {}
  }

  Future<void> resetView() async {
    vpYaw.value = 0;
    vpPitch.value = 0;
    await _invoke('resetView');
  }

  Future<void> setGyro(bool on) async {
    gyroOn.value = on;
    await _invoke('setGyro', {'on': on});
  }

  Future<void> _invoke(String method, [Map<String, dynamic>? args]) async {
    try {
      await _ch.invokeMethod<void>(method, args);
    } catch (_) {
      // 播放器可能已经释放, 控制类调用失败不打扰用户
    }
  }

  @override
  void onClose() {
    _closed = true;
    _ch.setMethodCallHandler(null);
    // fire-and-forget: native 侧 stop/release 在后台线程做(避免 ANR)
    unawaited(_invoke('release'));
    super.onClose();
  }
}
