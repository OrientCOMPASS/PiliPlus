import 'package:PiliPlus/models/local_media/vlc_media.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

/// libmedialibrary(VLC 媒体库)的 Dart 门面。
///
/// 对应 Kotlin 侧 `VlcLibraryBridge`(MethodChannel `piliplus/vlc_library`)。
/// 索引/续播/历史全部由 libml 原生持久化(与 VLC 安卓端同一套存储),
/// Dart 侧只做查询与展示。
class VlcLibrary extends GetxController {
  VlcLibrary._();

  static final VlcLibrary instance = VlcLibrary._();

  static const MethodChannel _ch = MethodChannel('piliplus/vlc_library');

  /// libml 初始化+首次扫描是否完成(onMedialibraryReady)
  final RxBool ready = false.obs;

  /// 扫描/索引进行中(onMedialibraryReady 之后还会因增量扫描再次翻转)
  final RxBool busy = false.obs;

  final RxnString lastError = RxnString();

  bool _initStarted = false;
  bool _handlerBound = false;

  void _bindHandler() {
    if (_handlerBound) {
      return;
    }
    _handlerBound = true;
    _ch.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onReady':
          ready.value = true;
          busy.value = false;
        case 'onIdle':
          busy.value = false;
      }
      return null;
    });
  }

  /// 初始化媒体库并开始扫描所有存储卷。幂等, 进入本地板块时调用。
  ///
  /// 需要存储读取权限(调用方先确保); 扫描在 libml 后台线程进行,
  /// 完成后经 `onReady` 事件翻转 [ready]。
  Future<bool> init() async {
    _bindHandler();
    if (_initStarted) {
      return true;
    }
    try {
      busy.value = true;
      final res = await _ch.invokeMethod<Map<dynamic, dynamic>>('init');
      _initStarted = true;
      if (res?.containsKey('error') == true) {
        lastError.value = 'VLC 媒体库初始化失败: ${res?['error']}';
        busy.value = false;
        return false;
      }
      return true;
    } catch (e) {
      lastError.value = 'VLC 媒体库初始化失败: $e';
      busy.value = false;
      return false;
    }
  }

  /// 全部视频条目(libml 已完成索引的部分; 扫描中会随进度增长, 配合
  /// [ready]/事件手动刷新)
  Future<List<VlcMediaItem>> videos() async {
    try {
      final res = await _ch.invokeMethod<List<dynamic>>('videos');
      return [
        for (final e in res ?? const [])
          if (e is Map) VlcMediaItem.fromMap(e),
      ];
    } catch (e) {
      lastError.value = '读取媒体库失败: $e';
      return const [];
    }
  }

  /// 最近播放(本机历史)
  Future<List<VlcMediaItem>> history() async {
    try {
      final res = await _ch.invokeMethod<List<dynamic>>('history');
      return [
        for (final e in res ?? const [])
          if (e is Map) VlcMediaItem.fromMap(e),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// 保存续播位置(播放器退出/切集时调用; libml 持久化)
  Future<void> setProgress(int mediaId, Duration time) async {
    if (mediaId < 0) {
      return;
    }
    try {
      await _ch.invokeMethod<bool>('setProgress', {
        'id': mediaId,
        'timeMs': time.inMilliseconds,
      });
    } catch (_) {
      // 进度保存失败不打扰播放
    }
  }

  /// 清除续播位置(看到结尾时)
  Future<void> clearProgress(int mediaId) => setProgress(mediaId, Duration.zero);

  /// 记入播放历史(网络流没有 ml id, 历史是它们唯一的"最近播放"入口)
  Future<void> addHistory(String uri, String title) async {
    try {
      await _ch.invokeMethod<bool>('addHistory', {'uri': uri, 'title': title});
    } catch (_) {}
  }

  /// 手动重扫; [full] 为 true 时强制全盘重建索引
  Future<void> rescan({bool full = false}) async {
    busy.value = true;
    ready.value = false;
    try {
      await _ch.invokeMethod<void>('rescan', {'full': full});
    } catch (e) {
      lastError.value = '重扫失败: $e';
      busy.value = false;
    }
  }

  /// 把目录排除出索引(如 Android/ 数据目录)
  Future<void> banFolder(String path) async {
    try {
      await _ch.invokeMethod<void>('banFolder', {'path': path});
    } catch (_) {}
  }
}
