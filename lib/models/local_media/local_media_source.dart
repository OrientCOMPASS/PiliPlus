import 'package:PiliPlus/models/common/enum_with_label.dart';
import 'package:collection/collection.dart';

/// 「本地」板块的来源类型。
///
/// 只列出播放器能直接播的协议: 安卓端打包的 FFmpeg 启用了
/// file/http/https/ftp/hls/tcp/tls(未启用 smb), 因此:
///   * 本机文件 -> file
///   * WebDAV / HTTP / FTP -> 由 mpv 直接播放完整 URL(凭据以 userinfo 形式带上)
///   * SMB/NFS 需要额外的客户端与本地代理, 暂未支持(见 docs/piliplayer.md)
enum LocalMediaSourceType with EnumWithLabel {
  device('本机存储'),
  webdav('WebDAV'),
  http('HTTP 直链'),
  ftp('FTP 直链'),
  ;

  @override
  final String label;
  const LocalMediaSourceType(this.label);

  /// 是否支持在应用内浏览目录
  bool get browsable => this == device || this == webdav;

  bool get isNetwork => this != device;
}

/// 一个媒体来源。
///
/// [LocalMediaSourceType.device] 时 [url] 为本机目录绝对路径;
/// 网络类型时 [url] 为共享根地址(可以带子目录), [username]/[password] 为凭据。
class LocalMediaSource {
  const LocalMediaSource({
    required this.type,
    required this.name,
    required this.url,
    this.username,
    this.password,
  });

  final LocalMediaSourceType type;
  final String name;
  final String url;
  final String? username;
  final String? password;

  bool get hasCredential =>
      (username?.isNotEmpty ?? false) || (password?.isNotEmpty ?? false);

  bool get canBrowse => type.browsable;

  /// 浏览的起始路径
  String get rootPath {
    if (type == LocalMediaSourceType.device) {
      return url;
    }
    final uri = Uri.tryParse(url);
    final p = uri?.path ?? '';
    return p.isEmpty ? '/' : p;
  }

  /// 播放地址的基址: 把凭据以 userinfo 形式写进 URL, 交给 mpv/FFmpeg 处理。
  /// 这样无需在应用内实现 HTTP/FTP 认证, 也不会在日志里额外暴露密码。
  String get playbackBase {
    if (type == LocalMediaSourceType.device) {
      return url;
    }
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme || !hasCredential) {
      return url;
    }
    final info =
        '${Uri.encodeComponent(username ?? '')}:'
        '${Uri.encodeComponent(password ?? '')}';
    final host = uri.host;
    final port = uri.hasPort && !uri.isPortDefault ? ':${uri.port}' : '';
    final p = uri.path;
    return '${uri.scheme}://$info@$host$port${p.isEmpty ? '/' : p}';
  }

  Map<String, dynamic> toJson() => {
    'type': type.index,
    'name': name,
    'url': url,
    if (username != null) 'username': username,
    if (password != null) 'password': password,
  };

  static LocalMediaSource? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final type = LocalMediaSourceType.values.elementAtOrNull(
      json['type'] is int ? json['type'] as int : -1,
    );
    final name = json['name'];
    final url = json['url'];
    if (type == null || name is! String || url is! String || url.isEmpty) {
      return null;
    }
    return LocalMediaSource(
      type: type,
      name: name,
      url: url,
      username: json['username'] as String?,
      password: json['password'] as String?,
    );
  }

  LocalMediaSource copyWith({
    LocalMediaSourceType? type,
    String? name,
    String? url,
    String? username,
    String? password,
  }) => LocalMediaSource(
    type: type ?? this.type,
    name: name ?? this.name,
    url: url ?? this.url,
    username: username ?? this.username,
    password: password ?? this.password,
  );

  @override
  bool operator ==(Object other) =>
      other is LocalMediaSource &&
      other.type == type &&
      other.name == name &&
      other.url == url &&
      other.username == username &&
      other.password == password;

  @override
  int get hashCode => Object.hash(type, name, url, username, password);

  @override
  String toString() => 'LocalMediaSource(${type.name}, $name, $url)';
}
