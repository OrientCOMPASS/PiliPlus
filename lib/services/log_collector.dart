import 'dart:io';

import 'package:flutter/services.dart';

/// 原生错误日志收集器(MethodChannel `piliplus/log_collector`)的 Dart 门面。
///
/// Kotlin 侧 `LogCollector` 维护一个进程内环形缓冲(4000 行):
///  - 后台线程抓取本进程 logcat 的 W/E/F 行与 VLC 引擎相关 tag;
///  - 三个 VLC 桥与 Dart 侧(经 [push])显式记录的错误(含堆栈)。
///
/// 「设置 → 日志」页用它展示引擎日志、合成导出文件(docs §18)。
/// 仅 Android 生效, 其余平台全部静默降级为空实现。
abstract final class NativeLogCollector {
  static const MethodChannel _ch = MethodChannel('piliplus/log_collector');

  static bool get _supported => Platform.isAndroid;

  /// 取回缓冲的日志文本(最近 [limit] 行); 平台不支持或通道未就绪时返回空串
  static Future<String> dump({int limit = 4000}) async {
    if (!_supported) {
      return '';
    }
    try {
      return await _ch.invokeMethod<String>('dump', {'limit': limit}) ?? '';
    } catch (_) {
      return '';
    }
  }

  /// 清空原生缓冲
  static Future<void> clear() async {
    if (!_supported) {
      return;
    }
    try {
      await _ch.invokeMethod<void>('clear');
    } catch (_) {}
  }

  /// 把 Dart 侧的错误/事件写进原生缓冲(与引擎日志合成一份, 方便导出)。
  /// fire-and-forget, 任何失败都静默。
  static Future<void> push(
    String tag,
    String msg, {
    String level = 'E',
  }) async {
    if (!_supported) {
      return;
    }
    try {
      await _ch.invokeMethod<void>('push', {
        'level': level,
        'tag': tag,
        'msg': msg,
      });
    } catch (_) {}
  }
}
