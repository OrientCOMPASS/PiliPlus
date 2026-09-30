import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/models/local_media/local_media_item.dart';
import 'package:PiliPlus/models/local_media/local_media_source.dart';
import 'package:PiliPlus/services/local_media_service.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:get/get.dart';

/// 媒体库里的一个文件夹(媒体文件数、总大小、最近修改时间)
class LocalMediaFolder {
  const LocalMediaFolder({
    required this.path,
    required this.name,
    required this.count,
    required this.totalSize,
    this.latest,
  });

  final String path;
  final String name;
  final int count;
  final int totalSize;
  final DateTime? latest;

  Map<String, dynamic> toJson() => {
    'path': path,
    'name': name,
    'count': count,
    'totalSize': totalSize,
    if (latest != null) 'latest': latest!.toIso8601String(),
  };

  static LocalMediaFolder? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final path = json['path'];
    final name = json['name'];
    if (path is! String || name is! String) {
      return null;
    }
    final latest = json['latest'];
    return LocalMediaFolder(
      path: path,
      name: name,
      count: json['count'] is int ? json['count'] as int : 0,
      totalSize: json['totalSize'] is int ? json['totalSize'] as int : 0,
      latest: latest is String ? DateTime.tryParse(latest) : null,
    );
  }
}

/// 本机媒体库扫描: 递归遍历存储卷, 按文件夹归组
/// (参照 VLC 安卓版「浏览/文件夹」的组织方式)。
///
/// 扫描结果缓存在本机, 下次进入板块立刻可见, 再按需重新扫描。
class LocalMediaLibrary {
  /// 跳过的目录名(应用私有目录、缩略图缓存等)
  static const Set<String> skipDirNames = {
    'android',
    'lost.dir',
    '.thumbnails',
    '.thumbdata',
    '.cache',
    'backup',
  };

  /// 单次扫描上限, 防止超大存储卡把 UI 拖死
  static const int maxFiles = 20000;
  static const int maxFolders = 4000;

  /// 进度刷新节流。
  ///
  /// 全盘递归扫描动辄上万个文件, 每发现一个文件就把 `scannedFiles`/`folders`
  /// 写进 Rx 会触发同样多次 `Obx` 重建(整张 ListView 重建), 首帧之后界面会
  /// 卡到看起来像「空白/没反应」。所以内部用普通 int 计数, 由定时器批量推送。
  static const Duration _progressInterval = Duration(milliseconds: 300);
  static const Duration _publishInterval = Duration(milliseconds: 1200);

  final RxList<LocalMediaFolder> folders = <LocalMediaFolder>[].obs;
  final RxBool scanning = false.obs;
  final RxnString lastError = RxnString();
  final RxInt scannedFiles = 0.obs;
  DateTime? lastScanAt;

  /// 已发现的媒体文件数(不走 Rx, 由 [_progressTimer] 批量同步)
  int _fileCount = 0;
  Timer? _progressTimer;
  DateTime? _lastPublish;

  /// 置位后 [_walk] 会尽快退出
  bool _abort = false;

  bool get hasCache => folders.isNotEmpty || lastScanAt != null;

  /// 读取上次扫描的缓存
  void loadCache() {
    final cached = GStorage.setting.get(SettingBoxKey.localMediaLibrary);
    if (cached is List) {
      final list = <LocalMediaFolder>[];
      for (final e in cached) {
        if (LocalMediaFolder.fromJson(e) case final folder?) {
          list.add(folder);
        }
      }
      folders.value = list;
    }
    final at = GStorage.setting.get(SettingBoxKey.localMediaScanTime);
    if (at is String) {
      lastScanAt = DateTime.tryParse(at);
    }
  }

  Future<void> saveCache() {
    lastScanAt = DateTime.now();
    return GStorage.setting.putAll({
      SettingBoxKey.localMediaLibrary: folders
          .map((e) => e.toJson())
          .toList(),
      SettingBoxKey.localMediaScanTime: lastScanAt!.toIso8601String(),
    });
  }

  /// 扫描所有存储卷
  Future<void> scan() async {
    if (scanning.value) {
      return;
    }
    scanning.value = true;
    lastError.value = null;
    _abort = false;
    _fileCount = 0;
    _lastPublish = null;
    scannedFiles.value = 0;
    final byFolder = <String, _FolderAgg>{};
    // 批量推送进度 / 阶段性结果, 避免每个文件都重建一次列表
    _progressTimer?.cancel();
    _progressTimer = Timer.periodic(
      _progressInterval,
      (_) => _flushProgress(byFolder),
    );
    try {
      if (!await LocalMediaService.ensureDevicePermission()) {
        lastError.value = '未获得存储读取权限，无法扫描本机视频';
        return;
      }
      final roots = await LocalMediaService.deviceSources();
      if (roots.isEmpty) {
        lastError.value = '没有可访问的存储卷';
        return;
      }
      for (final root in roots) {
        await _walk(root.url, byFolder);
      }
      folders.value = _snapshot(byFolder);
      await saveCache();
    } catch (err) {
      lastError.value = err.toString();
    } finally {
      _progressTimer?.cancel();
      _progressTimer = null;
      scannedFiles.value = _fileCount;
      scanning.value = false;
    }
  }

  /// 主动停掉扫描(板块销毁时调用)
  void cancelScan() {
    _abort = true;
    _progressTimer?.cancel();
    _progressTimer = null;
    if (scanning.value) {
      scanning.value = false;
    }
  }

  void _flushProgress(Map<String, _FolderAgg> byFolder) {
    if (scannedFiles.value != _fileCount) {
      scannedFiles.value = _fileCount;
    }
    // 已经有缓存时不要在扫描途中把列表清空(重扫会闪一下)
    if (byFolder.isEmpty) {
      return;
    }
    final now = DateTime.now();
    if (_lastPublish == null ||
        now.difference(_lastPublish!) >= _publishInterval) {
      _lastPublish = now;
      folders.value = _snapshot(byFolder);
    }
  }

  static List<LocalMediaFolder> _snapshot(Map<String, _FolderAgg> byFolder) =>
      byFolder.values
          .map(
            (e) => LocalMediaFolder(
              path: e.path,
              name: e.name,
              count: e.count,
              totalSize: e.totalSize,
              latest: e.latest,
            ),
          )
          .toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

  Future<void> _walk(String path, Map<String, _FolderAgg> byFolder) async {
    if (_abort || byFolder.length > maxFolders || _fileCount > maxFiles) {
      return;
    }
    final dir = Directory(path);
    final List<FileSystemEntity> entries;
    try {
      entries = await dir.list(followLinks: false).toList();
    } catch (_) {
      return; // 无权限或失效的目录直接跳过
    }
    for (final entity in entries) {
      if (_abort) {
        return;
      }
      final name = _baseName(entity.path);
      if (name.isEmpty || name.startsWith('.')) {
        continue;
      }
      if (entity is Directory) {
        if (skipDirNames.contains(name.toLowerCase())) {
          continue;
        }
        await _walk(entity.path, byFolder);
        continue;
      }
      if (entity is! File) {
        continue;
      }
      if (!LocalMediaExtensions.videos.contains(_ext(name))) {
        continue;
      }
      final agg = byFolder.putIfAbsent(path, () => _FolderAgg(path));
      agg.count++;
      _fileCount++;
      try {
        // ignore: avoid_slow_async_io
        final stat = await entity.stat();
        agg.totalSize += stat.size;
        final modified = stat.modified;
        if (agg.latest == null || modified.isAfter(agg.latest!)) {
          agg.latest = modified;
        }
      } catch (_) {
        // 拿不到属性就只计数
      }
    }
  }

  static String _baseName(String path) {
    final i = path.lastIndexOf(Platform.pathSeparator);
    if (i < 0) {
      return path;
    }
    final name = path.substring(i + 1);
    return name.isEmpty ? path : name;
  }

  static String _ext(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) {
      return '';
    }
    return name.substring(dot + 1).toLowerCase();
  }

  /// 某个文件夹下的可播放条目
  Future<List<LocalMediaItem>> itemsOf(LocalMediaFolder folder) async {
    final source = LocalMediaSource(
      type: LocalMediaSourceType.device,
      name: folder.name,
      url: folder.path,
    );
    final res = await LocalMediaService.list(
      source: source,
      path: folder.path,
      showHidden: false,
    );
    return res.dataOrNull ?? const [];
  }
}

class _FolderAgg {
  _FolderAgg(this.path);

  final String path;
  int count = 0;
  int totalSize = 0;
  DateTime? latest;

  String get name => LocalMediaLibrary._baseName(path);
}
