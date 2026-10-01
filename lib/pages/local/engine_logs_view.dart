import 'dart:io';

import 'package:PiliPlus/build_config.dart';
import 'package:PiliPlus/services/local_media/local_media_channel.dart';
import 'package:PiliPlus/services/local_media/log_ring.dart';
import 'package:PiliPlus/services/logger.dart';
import 'package:PiliPlus/utils/date_utils.dart';
import 'package:flutter/services.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// 引擎/Native 日志页（需求 §2.6）：
///  - 查看：native（libvlc/桥层，含堆栈）+ Dart 侧环形缓冲，可刷新/复制/清空
///  - 导出：应用与构建信息 + 设备信息 + Dart 错误报告 + 引擎日志 合成
///    一个文本文件，经系统分享面板导出
class EngineLogsPage extends StatefulWidget {
  const EngineLogsPage({super.key});

  @override
  State<EngineLogsPage> createState() => _EngineLogsPageState();
}

class _EngineLogsPageState extends State<EngineLogsPage> {
  final LocalMediaChannel _ch = LocalMediaChannel.instance;

  List<String> _nativeLines = const [];
  List<String> _dartLines = const [];
  bool _loading = false;
  Map<String, dynamic> _device = const {};
  Map<String, dynamic> _engine = const {};

  @override
  void initState() {
    super.initState();
    refresh();
  }

  Future<void> refresh() async {
    setState(() => _loading = true);
    try {
      final results = await Future.wait([
        _ch.logGet(),
        _ch.deviceInfo(),
        _ch.engineInfo(),
      ]);
      if (!mounted) return;
      setState(() {
        _nativeLines = results[0] as List<String>;
        _device = (results[1] as Map).cast<String, dynamic>();
        _engine = (results[2] as Map).cast<String, dynamic>();
        _dartLines = LocalLogRing.instance.snapshot();
      });
    } catch (e) {
      SmartDialog.showToast('读取日志失败：$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _copyAll() async {
    final text = [..._nativeLines, ..._dartLines].join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    SmartDialog.showToast('已复制 ${_nativeLines.length + _dartLines.length} 行');
  }

  Future<void> _clearAll() async {
    await _ch.logClear();
    LocalLogRing.instance.clear();
    refresh();
    SmartDialog.showToast('已清空');
  }

  Future<void> _export() async {
    try {
      SmartDialog.showLoading(msg: '生成诊断文件…');
      final buffer = StringBuffer();
      buffer.writeln('===== PiliPlus 诊断文件 =====');
      buffer.writeln('导出时间: ${DateFormatUtils.format(DateTime.now().millisecondsSinceEpoch ~/ 1000, format: DateFormatUtils.longFormatDs)}');
      buffer.writeln();
      buffer.writeln('--- 应用与构建信息 ---');
      buffer.writeln('版本: ${BuildConfig.versionName}+${BuildConfig.versionCode}');
      buffer.writeln('Commit: ${BuildConfig.commitHash}');
      buffer.writeln('构建时间: ${DateFormatUtils.format(BuildConfig.buildTime, format: DateFormatUtils.longFormatDs)}');
      buffer.writeln('引擎: libvlc ${_engine['version'] ?? '?'}, VR 扩展版本: ${_engine['vrVersion'] ?? 0}');
      if (_engine['initError'] != null) {
        buffer.writeln('引擎初始化错误: ${_engine['initError']}');
      }
      buffer.writeln();
      buffer.writeln('--- 设备信息 ---');
      _device.forEach((k, v) => buffer.writeln('$k: $v'));
      buffer.writeln();
      buffer.writeln('--- Dart 错误报告 (Catcher2) ---');
      try {
        final logFile = await LoggerUtils.getLogsPath();
        if (logFile.existsSync()) {
          final content = await logFile.readAsString();
          buffer.writeln(content.isEmpty ? '(空)' : content);
        } else {
          buffer.writeln('(无日志文件——「记录日志」开关可能未开启)');
        }
      } catch (e) {
        buffer.writeln('(读取失败: $e)');
      }
      buffer.writeln();
      buffer.writeln('--- Dart 侧环形日志 ---');
      buffer.writeln(_dartLines.isEmpty ? '(空)' : _dartLines.join('\n'));
      buffer.writeln();
      buffer.writeln('--- 引擎/Native 日志（本进程 logcat 摘录） ---');
      buffer.writeln(_nativeLines.isEmpty ? '(空)' : _nativeLines.join('\n'));

      final dir = await getTemporaryDirectory();
      final file = File(
        p.join(
          dir.path,
          'PiliPlus_diag_${BuildConfig.commitHash == 'N/A' ? 'dev' : BuildConfig.commitHash.substring(0, (BuildConfig.commitHash.length).clamp(0, 9))}_'
              '${DateTime.now().millisecondsSinceEpoch}.txt',
        ),
      );
      await file.writeAsString(buffer.toString());
      SmartDialog.dismiss();
      await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path)], text: 'PiliPlus 诊断文件'),
      );
    } catch (e) {
      SmartDialog.dismiss();
      SmartDialog.showToast('导出失败：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('引擎日志'),
        actions: [
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : refresh,
          ),
          IconButton(
            tooltip: '复制全部',
            icon: const Icon(Icons.copy_all_outlined),
            onPressed: _copyAll,
          ),
          IconButton(
            tooltip: '清空',
            icon: const Icon(Icons.delete_outline),
            onPressed: _clearAll,
          ),
          IconButton(
            tooltip: '导出诊断文件',
            icon: const Icon(Icons.ios_share),
            onPressed: _export,
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Text(
              '引擎: libvlc ${_engine['version'] ?? '?'} · '
              'VR 扩展: ${(_engine['vrVersion'] as num? ?? 0) > 0 ? 'v${_engine['vrVersion']}' : '无（标准引擎）'} · '
              'native ${_nativeLines.length} 行 / dart ${_dartLines.length} 行',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: SelectableText(
                [..._nativeLines, '', '---- dart ----', ..._dartLines].join('\n'),
                style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
