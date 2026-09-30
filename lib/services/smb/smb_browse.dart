import 'local_media_proxy.dart';
import 'smb2_client.dart';

/// SMB 共享里的一条记录(纯 Dart, 不依赖 Flutter, 便于在沙盒里直接联调)
class SmbBrowseEntry {
  const SmbBrowseEntry({
    required this.name,
    required this.remotePath,
    required this.isDirectory,
    this.size,
    this.modified,
  });

  final String name;

  /// 共享内相对路径, 反斜杠分隔(如 `videos\剧集\第1集.mp4`)
  final String remotePath;
  final bool isDirectory;
  final int? size;
  final DateTime? modified;

  @override
  String toString() =>
      'SmbBrowseEntry(${isDirectory ? 'D' : 'F'} $remotePath, $size)';
}

/// SMB 浏览/播放地址解析。
///
/// 这里刻意不引入 Flutter 依赖: 沙盒里可以用真实的 smbd 直接跑
/// (`~/.ci/smb_testbed.sh`), 而不必依赖只能在 CI 上验证的 Flutter 构建。
abstract final class SmbBrowse {
  /// 列出 `\\host\share\path` 的内容。每次调用新建一条连接(局域网握手 ~50ms),
  /// 好处是无状态: 不会因会话过期/服务端重启留下坏连接。
  static Future<List<SmbBrowseEntry>> list({
    required String host,
    int port = 445,
    required String share,
    String path = '',
    String? user,
    String? password,
    String domain = '',
    bool showHidden = false,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final client = Smb2Client(host: host, port: port);
    try {
      await client.connect(
        user: user,
        password: password,
        domain: domain,
        timeout: timeout,
      );
      await client.treeConnect(share);
      final entries = await client.listDirectory(path);
      final base = normalizePath(path);
      final result = <SmbBrowseEntry>[];
      for (final e in entries) {
        if (!showHidden && e.name.startsWith('.')) {
          continue;
        }
        result.add(
          SmbBrowseEntry(
            name: e.name,
            remotePath: base.isEmpty ? e.name : '$base\\${e.name}',
            isDirectory: e.isDirectory,
            size: e.isDirectory ? null : e.size,
            modified: e.modified,
          ),
        );
      }
      return result;
    } finally {
      await client.close();
    }
  }

  /// 连通性检查, 返回该目录下的条目数; 失败时抛出 [SmbException]
  static Future<int> probe({
    required String host,
    int port = 445,
    required String share,
    String path = '',
    String? user,
    String? password,
    String domain = '',
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final entries = await list(
      host: host,
      port: port,
      share: share,
      path: path,
      user: user,
      password: password,
      domain: domain,
      timeout: timeout,
    );
    return entries.length;
  }

  /// 注册到本机回环代理并返回可交给 mpv 的 http URL
  static Future<String> serveUrl({
    required String host,
    int port = 445,
    required String share,
    required String remotePath,
    String? user,
    String? password,
    String domain = '',
  }) {
    return LocalMediaProxy.instance.serve(
      SmbTarget(
        host: host,
        port: port,
        share: share,
        path: normalizePath(remotePath),
        user: user,
        password: password,
        domain: domain,
      ),
    );
  }

  /// 把路径统一成"共享内相对路径"(反斜杠分隔、无前导分隔符)
  static String normalizePath(String path) {
    var p = path.replaceAll('/', '\\');
    while (p.startsWith('\\')) {
      p = p.substring(1);
    }
    while (p.endsWith('\\')) {
      p = p.substring(0, p.length - 1);
    }
    return p;
  }

  /// SMB 条目的稳定标识(不含凭据), 用作续播进度的 key
  static String uri({
    required String host,
    int port = 445,
    required String share,
    required String remotePath,
  }) {
    final portPart = port == 445 ? '' : ':$port';
    final clean = normalizePath(remotePath).replaceAll('\\', '/');
    final encoded = clean
        .split('/')
        .where((e) => e.isNotEmpty)
        .map(_encodeSegment)
        .join('/');
    final sharePart = _encodeSegment(share);
    return 'smb://$host$portPart/$sharePart'
        '${encoded.isEmpty ? '' : '/$encoded'}';
  }

  static String _encodeSegment(String segment) =>
      Uri.encodeComponent(_safeDecode(segment));

  /// `Uri.pathSegments` 已经解码过一次, 再解一次可能因为字面量 '%' 抛异常,
  /// 因此解码一律走这里, 失败就原样返回
  static String _safeDecode(String value) {
    try {
      return Uri.decodeComponent(value);
    } catch (_) {
      return value;
    }
  }

  /// 解析 `smb://host[:port]/share[/子目录]`
  static ({String host, int port, String share, String path})? parseEndpoint(
    String url,
  ) {
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
      share: _safeDecode(segments.first),
      path: segments.length > 1
          ? segments.sublist(1).map(_safeDecode).join('\\')
          : '',
    );
  }
}
