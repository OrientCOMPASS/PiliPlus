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
  smb('SMB/CIFS'),
  webdav('WebDAV'),
  http('HTTP 直链'),
  ftp('FTP 直链'),
  ;

  @override
  final String label;
  const LocalMediaSourceType(this.label);

  /// 是否支持在应用内浏览目录
  bool get browsable => this == device || this == webdav || this == smb;

  bool get isNetwork => this != device;

  /// 是否需要本机代理转发才能播放。
  /// 安卓端打包的 FFmpeg 没有 smb 协议, 所以 SMB 走回环 HTTP 代理
  /// (见 `services/smb/local_media_proxy.dart`)。
  bool get needsProxy => this == smb;
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
    this.domain,
    this.address,
  });

  final LocalMediaSourceType type;
  final String name;
  final String url;
  final String? username;
  final String? password;

  /// SMB 域/工作组(其它类型用不到)
  final String? domain;

  /// SMB: url 里写的是主机名时, 这里记录发现阶段拿到的 IP 作为解析兜底
  /// (NBNS 广播在个别网络里会被拦, 有它在就永远连得上)
  final String? address;

  bool get hasCredential =>
      (username?.isNotEmpty ?? false) || (password?.isNotEmpty ?? false);

  bool get canBrowse => type.browsable;

  /// 解析 `smb://host[:port]/share[/子目录]`。
  /// URL 里没写共享名(主机级来源, 见 [isSmbHostRoot])时返回 null。
  ({String host, int port, String share, String path})? get smbEndpoint {
    if (type != LocalMediaSourceType.smb) {
      return null;
    }
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) {
      return null;
    }
    final segments = uri.pathSegments.where((e) => e.isNotEmpty).toList();
    if (segments.isEmpty) {
      return null;
    }
    return (
      host: uri.host,
      port: uri.hasPort && uri.port > 0 ? uri.port : 445,
      share: segments.first,
      path: segments.length > 1 ? segments.sublist(1).join(r'\') : '',
    );
  }

  /// 只解析主机与端口(不要求 URL 里带共享名)
  ({String host, int port})? get smbHost {
    if (type != LocalMediaSourceType.smb) {
      return null;
    }
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) {
      return null;
    }
    return (host: uri.host, port: uri.hasPort && uri.port > 0 ? uri.port : 445);
  }

  /// **主机级** SMB 来源: URL 形如 `smb://NAS`(没有共享名)。
  ///
  /// 这是第四轮改的交互: 连接一台主机后直接进入它, 主机本身当作一个目录,
  /// 它共享出来的每个目录是其中的一级子目录(与 VLC/资源管理器一致),
  /// 而不是弹窗让用户挑一个共享再单独保存成一条快捷方式。
  /// 浏览到根时列共享(SRVSVC NetShareEnum), 进入某个共享后再按 SMB 目录列。
  bool get isSmbHostRoot =>
      type == LocalMediaSourceType.smb &&
      smbHost != null &&
      smbEndpoint == null;

  /// 浏览的起始路径。
  /// SMB 共享级来源: 共享名已经在 [smbEndpoint] 里, 这里只能是**共享内**的
  /// 相对路径(此前的 bug: 返回 `/共享名` 会让浏览器在共享里再找一层同名目录,
  /// 打开手动填写的共享必然 OBJECT_NAME_NOT_FOUND)。
  /// SMB 主机级来源: 空串, 由服务层解释为"列共享"。
  String get rootPath {
    if (type == LocalMediaSourceType.device) {
      return url;
    }
    if (type == LocalMediaSourceType.smb) {
      return smbEndpoint?.path ?? '';
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
    // Uri.port 在未显式指定端口时会返回该 scheme 的默认端口, 这里据此决定是否写出端口
    final port = uri.port;
    final portPart = port == defaultPortFor(uri.scheme) || port == 0
        ? ''
        : ':$port';
    final p = uri.path;
    return '${uri.scheme}://$info@$host$portPart${p.isEmpty ? '/' : p}';
  }

  /// 常见协议的默认端口(未知协议返回 0, 此时不写出端口)
  static int defaultPortFor(String scheme) => switch (scheme.toLowerCase()) {
    'http' => 80,
    'https' => 443,
    'ftp' => 21,
    'rtsp' => 554,
    _ => 0,
  };

  Map<String, dynamic> toJson() => {
    'type': type.index,
    'name': name,
    'url': url,
    if (username != null) 'username': username,
    if (password != null) 'password': password,
    if (domain != null) 'domain': domain,
    if (address != null) 'address': address,
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
      domain: json['domain'] as String?,
      address: json['address'] as String?,
    );
  }

  LocalMediaSource copyWith({
    LocalMediaSourceType? type,
    String? name,
    String? url,
    String? username,
    String? password,
    String? domain,
    String? address,
  }) => LocalMediaSource(
    type: type ?? this.type,
    name: name ?? this.name,
    url: url ?? this.url,
    username: username ?? this.username,
    password: password ?? this.password,
    domain: domain ?? this.domain,
    address: address ?? this.address,
  );

  @override
  bool operator ==(Object other) =>
      other is LocalMediaSource &&
      other.type == type &&
      other.name == name &&
      other.url == url &&
      other.username == username &&
      other.password == password &&
      other.domain == domain;

  @override
  int get hashCode => Object.hash(
    type,
    name,
    url,
    username,
    password,
    domain,
  );

  @override
  String toString() => 'LocalMediaSource(${type.name}, $name, $url)';
}
