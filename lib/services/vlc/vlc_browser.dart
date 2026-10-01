import 'dart:async';

import 'package:PiliPlus/models/local_media/vlc_media.dart';
import 'package:flutter/services.dart';

/// VLC 网络浏览(libvlc MediaBrowser)的 Dart 门面。
///
/// 对应 Kotlin 侧 `VlcBrowserBridge`(MethodChannel `piliplus/vlc_browser`)。
/// smb/ftp/nfs/upnp 的发现与目录浏览全部由 libvlc 原生完成 —— 不再有
/// Dart 侧 SMB2 客户端与回环 HTTP 代理, 播放时把 smb:// 等 URI 直接交给
/// libvlc(与 VLC 安卓端同一套 access 模块, 随机读定位由 libsmb2 负责)。
///
/// 一次只有一个活动会话(与 Kotlin 侧的 token 语义一致): 开始新浏览自动
/// 作废旧会话的事件流。
class VlcBrowser {
  VlcBrowser._();

  static final VlcBrowser instance = VlcBrowser._();

  static const MethodChannel _ch = MethodChannel('piliplus/vlc_browser');

  bool _handlerBound = false;

  // 旧会话的事件由 Kotlin 侧按 token 过滤(见 VlcBrowserBridge), Dart 只需
  // 维护"当前会话"的回调
  void _bindHandler() {
    if (_handlerBound) {
      return;
    }
    _handlerBound = true;
    _ch.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onItem':
          if (call.arguments is Map) {
            _onItem?.call(VlcBrowseItem.fromMap(call.arguments as Map));
          }
        case 'onBrowseEnd':
          _onEnd?.call();
        case 'onError':
          final msg = (call.arguments as Map?)?['message'] as String?;
          _onError?.call(msg ?? '浏览失败');
        case 'onDumpProgress':
          final pct = (call.arguments as Map?)?['progress'];
          if (pct is num) {
            _onDumpProgress?.call(pct.toDouble());
          }
        case 'onDumpFinished':
          final ok = (call.arguments as Map?)?['ok'] == true;
          _onDumpFinished?.call(ok);
          _onDumpProgress = null;
          _onDumpFinished = null;
      }
      return null;
    });
  }

  void Function(double progress)? _onDumpProgress;
  void Function(bool ok)? _onDumpFinished;

  /// 下载网络文件到本机路径(libvlc Dumper; 进度/完成经回调, 一次一个任务)
  Future<void> dump(
    String uri,
    String dest, {
    void Function(double progress)? onProgress,
    void Function(bool ok)? onFinished,
  }) async {
    _bindHandler();
    _onDumpProgress = onProgress;
    _onDumpFinished = onFinished;
    try {
      await _ch.invokeMethod<void>('dump', {'uri': uri, 'dest': dest});
    } catch (e) {
      _onDumpProgress = null;
      _onDumpFinished = null;
      onFinished?.call(false);
    }
  }

  Future<void> cancelDump() async {
    _onDumpProgress = null;
    _onDumpFinished = null;
    try {
      await _ch.invokeMethod<void>('cancelDump');
    } catch (_) {}
  }

  void Function(VlcBrowseItem item)? _onItem;
  void Function()? _onEnd;
  void Function(String message)? _onError;

  /// 发现局域网 SMB 共享(VLC「网络」页同款)。事件到达 [onItem],
  /// 结束回调 [onEnd]。
  Future<void> discoverShares({
    required void Function(VlcBrowseItem item) onItem,
    void Function()? onEnd,
    void Function(String message)? onError,
  }) async {
    _bindHandler();
    _onItem = onItem;
    _onEnd = onEnd;
    _onError = onError;
    try {
      await _ch.invokeMethod<void>('discoverShares');
    } catch (e) {
      onError?.call('$e');
    }
  }

  /// 浏览目录(smb://host/share/dir/、ftp://…、file:///… 均可)
  Future<void> browse(
    String uri, {
    bool showHidden = false,
    required void Function(VlcBrowseItem item) onItem,
    void Function()? onEnd,
    void Function(String message)? onError,
  }) async {
    _bindHandler();
    _onItem = onItem;
    _onEnd = onEnd;
    _onError = onError;
    try {
      await _ch.invokeMethod<void>('browse', {
        'uri': uri,
        'showHidden': showHidden,
      });
    } catch (e) {
      onError?.call('$e');
    }
  }

  /// 结束当前会话(离开页面时调用, 免得事件继续往已销毁的 UI 上打)
  Future<void> stop() async {
    _onItem = null;
    _onEnd = null;
    _onError = null;
    try {
      await _ch.invokeMethod<void>('stop');
    } catch (_) {}
  }
}
