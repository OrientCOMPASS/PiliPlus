/// 本地/局域网媒体 —— VLC 引擎侧的数据模型。
///
/// 第十二轮起本地板块整体改由 libvlc/libmedialibrary 驱动
/// (见 docs/piliplayer.md §17), 原 Dart 扫描/SMB2 客户端/回环代理一并废弃。
library;

/// libmedialibrary 索引出的媒体条目(Kotlin 侧 `describe(MediaWrapper)` 的映射)
class VlcMediaItem {
  const VlcMediaItem({
    required this.id,
    required this.title,
    required this.uri,
    this.lengthMs = 0,
    this.timeMs = 0,
    this.width = 0,
    this.height = 0,
    this.playCount = 0,
    this.fileName = '',
  });

  factory VlcMediaItem.fromMap(Map<dynamic, dynamic> m) => VlcMediaItem(
    id: (m['id'] as num?)?.toInt() ?? -1,
    title: m['title'] as String? ?? '',
    uri: m['uri'] as String? ?? '',
    lengthMs: (m['lengthMs'] as num?)?.toInt() ?? 0,
    timeMs: (m['timeMs'] as num?)?.toInt() ?? 0,
    width: (m['width'] as num?)?.toInt() ?? 0,
    height: (m['height'] as num?)?.toInt() ?? 0,
    playCount: (m['playCount'] as num?)?.toInt() ?? 0,
    fileName: m['fileName'] as String? ?? '',
  );

  final int id;
  final String title;

  /// 可直接交给 libvlc 播放的 URI(file:///…、smb://… 等)
  final String uri;
  final int lengthMs;

  /// 续播位置(libml 持久化, 与 VLC 同一存储)
  final int timeMs;
  final int width;
  final int height;
  final int playCount;
  final String fileName;

  Duration get duration => Duration(milliseconds: lengthMs);
  Duration get progress => Duration(milliseconds: timeMs);

  /// 是否看到接近结尾(结尾前 10 秒内视为看完, 不再显示续播进度)
  bool get finished =>
      lengthMs > 0 && timeMs > 0 && lengthMs - timeMs < 10 * 1000;

  /// 本机路径(file:///… → /storage/…); 非 file URI 返回 null
  String? get filePath {
    if (!uri.startsWith('file://')) {
      return null;
    }
    return Uri.parse(uri).toFilePath();
  }

  /// 所在文件夹的绝对路径(媒体库按文件夹归组用)
  String get folderPath {
    final p = filePath ?? uri;
    final i = p.lastIndexOf('/');
    return i > 0 ? p.substring(0, i) : p;
  }

  String get folderName {
    final p = folderPath;
    final i = p.lastIndexOf('/');
    final name = i >= 0 && i < p.length - 1 ? p.substring(i + 1) : p;
    return name.isEmpty ? '根目录' : name;
  }

  /// 展示名: ML 的标题元数据缺失时退回文件名
  String get displayName => title.isNotEmpty
      ? title
      : (fileName.isNotEmpty ? fileName : uri);

  VlcMediaItem copyWith({int? timeMs, int? playCount}) => VlcMediaItem(
    id: id,
    title: title,
    uri: uri,
    lengthMs: lengthMs,
    timeMs: timeMs ?? this.timeMs,
    width: width,
    height: height,
    playCount: playCount ?? this.playCount,
    fileName: fileName,
  );

  @override
  bool operator ==(Object other) =>
      other is VlcMediaItem && other.id == id && other.uri == uri;

  @override
  int get hashCode => Object.hash(id, uri);
}

/// 网络浏览条目(Kotlin 侧 MediaBrowser `describe(IMedia)` 的映射)
class VlcBrowseItem {
  const VlcBrowseItem({
    required this.name,
    required this.uri,
    this.isDir = false,
    this.durationMs = 0,
  });

  factory VlcBrowseItem.fromMap(Map<dynamic, dynamic> m) => VlcBrowseItem(
    name: m['name'] as String? ?? '',
    uri: m['uri'] as String? ?? '',
    isDir: m['isDir'] as bool? ?? false,
    durationMs: (m['durationMs'] as num?)?.toInt() ?? 0,
  );

  final String name;
  final String uri;
  final bool isDir;
  final int durationMs;

  /// 是不是可播放的媒体(目录以外的都交给 libvlc 去试, 白名单不再由我们维护
  /// —— VLC 支持的格式远比之前打包的 FFmpeg 白名单宽)
  bool get isPlayable => !isDir && uri.isNotEmpty;
}

/// 手动保存的网络共享(书签), 存 Hive `setting` 盒子
class VlcSavedShare {
  const VlcSavedShare({required this.name, required this.uri});

  factory VlcSavedShare.fromMap(Map<dynamic, dynamic> m) => VlcSavedShare(
    name: m['name'] as String? ?? '',
    uri: m['uri'] as String? ?? '',
  );

  final String name;
  final String uri;

  Map<String, dynamic> toMap() => {'name': name, 'uri': uri};

  /// 展示用: 隐藏 URL 里的账号密码
  String get maskedUri {
    final u = Uri.tryParse(uri);
    if (u == null || u.userInfo.isEmpty) {
      return uri;
    }
    return uri.replaceFirst('${u.userInfo}@', '***@');
  }
}

/// 媒体库列表排序
enum VlcMediaSort {
  folder('按文件夹'),
  name('按名称'),
  duration('按时长'),
  progress('按续播进度');

  final String label;
  const VlcMediaSort(this.label);
}
