import 'package:PiliPlus/services/smb/local_media_proxy.dart';
// SmbServerInfo(NTLM CHALLENGE 里解析出的服务端身份)定义在 smb2_client.dart;
// 池化之后本文件不再直接构造 Smb2Client, 所以只 show 用到的这一个符号
import 'package:PiliPlus/services/smb/smb2_client.dart' show SmbServerInfo;
import 'package:PiliPlus/services/smb/smb_session_pool.dart';
import 'package:PiliPlus/services/smb/srvsvc.dart';

/// [SmbBrowse.listShares] 的结果: 共享列表 + 服务端身份 + 实际连上的地址
class SmbShareListResult {
  const SmbShareListResult({
    required this.shares,
    this.serverInfo,
    this.resolvedAddress,
  });

  final List<SmbShare> shares;
  final SmbServerInfo? serverInfo;
  final String? resolvedAddress;

  /// 用户视角可浏览的共享(过滤打印/IPC/隐藏共享), 与 VLC 行为一致
  List<SmbShare> get browsable =>
      shares.where((s) => s.isBrowsable).toList();
}

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
  /// 列出 `\\host\share\path` 的内容。
  ///
  /// 会话走 [SmbSessionPool] 复用: 以前每次列目录都要重新
  /// NEGOTIATE + NTLM 握手 + TREE_CONNECT(局域网里 100~300ms), 逐层点目录、
  /// 以及递归检索(一个目录一次)时体感非常明显。VLC/libsmb2 也是复用会话的。
  static Future<List<SmbBrowseEntry>> list({
    required String host,
    int port = 445,
    required String share,
    String path = '',
    String? user,
    String? password,
    String domain = '',
    bool showHidden = false,
    String? address,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final entries = await SmbSessionPool.instance.run(
      host: host,
      port: port,
      share: share,
      user: user,
      password: password,
      domain: domain,
      address: address,
      timeout: timeout,
      body: (client) => client.listDirectory(path),
    );
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
  }

  /// 连通性检查, 返回该目录下的条目数; 失败时抛出 SmbException(见 smb2_client.dart)
  static Future<int> probe({
    required String host,
    int port = 445,
    required String share,
    String path = '',
    String? user,
    String? password,
    String domain = '',
    String? address,
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
      address: address,
      timeout: timeout,
    );
    return entries.length;
  }

  /// 枚举一台主机的共享列表(SRVSVC NetShareEnum, 与 VLC/资源管理器同款做法),
  /// 顺带返回服务端自报的身份(用于"尽量以主机名展示")。
  ///
  /// 匿名被拒时会抛 SmbException(`isAuthFailure`), 上层应引导输入凭据。
  static Future<SmbShareListResult> listShares({
    required String host,
    int port = 445,
    String? user,
    String? password,
    String domain = '',
    String? address,
    Duration timeout = const Duration(seconds: 10),
  }) {
    // 共享枚举走 IPC$ 这条 tree, 所以池的 key 用 IPC$, 与磁盘共享的会话互不干扰。
    // 主机根目录每次进来都要枚举一遍, 复用它省掉一整套握手。
    return SmbSessionPool.instance.run(
      host: host,
      port: port,
      share: 'IPC\$',
      user: user,
      password: password,
      domain: domain,
      address: address,
      timeout: timeout,
      body: (client) async {
        final shares = await Srvsvc.listShares(client);
        return SmbShareListResult(
          shares: shares,
          serverInfo: client.serverInfo,
          resolvedAddress: client.resolvedAddress,
        );
      },
    );
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
    String? address,
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
        address: address,
      ),
    );
  }

  /// 主机级地址: `smb://host[:port]`(不带共享名)。
  /// [host] 必须是能安全写进 URL 的形式(主机名或 IP), 调用方负责。
  static String hostUri({required String host, int port = 445}) {
    final portPart = port == 445 ? '' : ':$port';
    return 'smb://$host$portPart';
  }

  /// 把"主机内路径"拆成 (共享名, 共享内相对路径)。
  /// 主机级来源浏览时, 路径的第一段就是共享名。
  static (String, String) splitSharePath(String path) {
    final p = normalizePath(path);
    if (p.isEmpty) {
      return ('', '');
    }
    final i = p.indexOf('\\');
    return i < 0 ? (p, '') : (p.substring(0, i), p.substring(i + 1));
  }

  /// 把路径统一成"共享内相对路径"(反斜杠分隔、无前导分隔符)
  static String normalizePath(String path) {
    var p = path.replaceAll('/', '\\').replaceAll(RegExp(r'\\{2,}'), '\\');
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
