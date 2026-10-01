/// Data models for the local media module (library / network / player).
library;

class LocalVideo {
  final int id;
  final String name;
  final String path;
  final String uri;
  final int durationMs;
  final int sizeBytes;
  final int dateAddedMs;
  final int bucketId;
  final String bucketName;
  final String volume;

  LocalVideo({
    required this.id,
    required this.name,
    required this.path,
    required this.uri,
    required this.durationMs,
    required this.sizeBytes,
    required this.dateAddedMs,
    required this.bucketId,
    required this.bucketName,
    required this.volume,
  });

  factory LocalVideo.fromMap(Map map) => LocalVideo(
    id: (map['id'] as num).toInt(),
    name: map['name'] as String? ?? '',
    path: map['path'] as String? ?? '',
    uri: map['uri'] as String? ?? '',
    durationMs: (map['durationMs'] as num?)?.toInt() ?? 0,
    sizeBytes: (map['sizeBytes'] as num?)?.toInt() ?? 0,
    dateAddedMs: (map['dateAddedMs'] as num?)?.toInt() ?? 0,
    bucketId: (map['bucketId'] as num?)?.toInt() ?? 0,
    bucketName: map['bucketName'] as String? ?? '',
    volume: map['volume'] as String? ?? '',
  );

  String get titleWithoutExtension {
    final i = name.lastIndexOf('.');
    return i > 0 ? name.substring(0, i) : name;
  }
}

class LocalFolder {
  final int bucketId;
  final String name;
  final String path;
  final String volume;
  final int count;
  final int totalDurationMs;
  final int latestMs;

  LocalFolder({
    required this.bucketId,
    required this.name,
    required this.path,
    required this.volume,
    required this.count,
    required this.totalDurationMs,
    required this.latestMs,
  });
}

class NetItem {
  final String name;
  final String uri;
  final bool isDir;
  final int type;
  final int durationMs;

  NetItem({
    required this.name,
    required this.uri,
    required this.isDir,
    required this.type,
    this.durationMs = 0,
  });

  factory NetItem.fromMap(Map map) => NetItem(
    name: map['name'] as String? ?? '',
    uri: map['uri'] as String? ?? '',
    isDir: map['isDir'] as bool? ?? false,
    type: (map['type'] as num?)?.toInt() ?? 0,
    durationMs: (map['durationMs'] as num?)?.toInt() ?? 0,
  );

  String get scheme {
    final i = uri.indexOf('://');
    return i > 0 ? uri.substring(0, i) : '';
  }
}

/// Bookmarked network source (persisted locally; credentials included but
/// never displayed or logged — UI always shows the redacted form).
class NetBookmark {
  final String name;
  final String url;

  NetBookmark({required this.name, required this.url});

  Map<String, dynamic> toMap() => {'name': name, 'url': url};

  factory NetBookmark.fromMap(Map map) => NetBookmark(
    name: map['name'] as String? ?? '',
    url: map['url'] as String? ?? '',
  );

  /// smb://user:pass@host/share -> smb://user:***@host/share
  String get redactedUrl =>
      url.replaceFirstMapped(
        RegExp(r'://([^/@:]+):([^@/]+)@'),
        (m) => '://${m.group(1)}:***@',
      );
}

/// VR rendering matrix values (mirrors the native/libvlc contract).
enum VrProjection {
  auto(0, '自动'),
  flat(1, '平面 2D'),
  e360(2, '360°'),
  e180(3, '180°');

  final int value;
  final String label;
  const VrProjection(this.value, this.label);

  static VrProjection fromValue(int v) =>
      VrProjection.values.firstWhere((e) => e.value == v, orElse: () => auto);
}

enum VrStereo {
  auto(0, '自动'),
  mono(1, '单目 2D'),
  sbs(2, '左右 3D'),
  tb(3, '上下 3D');

  final int value;
  final String label;
  const VrStereo(this.value, this.label);

  static VrStereo fromValue(int v) =>
      VrStereo.values.firstWhere((e) => e.value == v, orElse: () => auto);
}

enum VrEye {
  left(0, '左眼'),
  right(1, '右眼');

  final int value;
  final String label;
  const VrEye(this.value, this.label);
}
