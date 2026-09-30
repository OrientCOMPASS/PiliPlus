import 'dart:async';
import 'dart:io';
import 'dart:math' show min;

import 'smb2_client.dart';

/// 一个可被代理播放的 SMB 对象
class SmbTarget {
  const SmbTarget({
    required this.host,
    this.port = 445,
    required this.share,
    required this.path,
    this.user,
    this.password,
    this.domain = '',
  });

  final String host;
  final int port;
  final String share;

  /// 共享内相对路径(反斜杠或正斜杠都可)
  final String path;
  final String? user;
  final String? password;
  final String domain;

  String get displayName => '\\\\$host\\$share\\${path.replaceAll('/', r'\')}';

  @override
  String toString() => 'SmbTarget($displayName)';
}

/// 本机回环 HTTP 代理。
///
/// 为什么需要它: 安卓端打包的 FFmpeg 只启用了 file/http/https/ftp/hls 等协议,
/// **没有 smb**, 所以 mpv 打不开 smb:// 地址。这里把 SMB 文件以
/// `http://127.0.0.1:<随机端口>/s/<token>` 的形式暴露给 mpv, 支持 Range 请求,
/// 于是 mpv 的 seek / 缓冲 / 硬件解码全部照常用, 且流量不出本机。
///
/// 安全边界: 只监听 loopback、token 不可枚举、不提供目录列表、
/// 只能访问显式注册过的对象。
class LocalMediaProxy {
  LocalMediaProxy._();

  static final LocalMediaProxy instance = LocalMediaProxy._();

  /// 单次 READ 的块大小: 512KB(信用消耗 8, 兼顾吞吐与内存)
  static const int chunkSize = 512 * 1024;

  HttpServer? _server;
  final Map<String, SmbTarget> _targets = {};
  int _seq = 0;
  Future<void>? _starting;

  /// 代理基址, 未启动时为 null
  String? get baseUrl {
    final server = _server;
    return server == null ? null : 'http://127.0.0.1:${server.port}';
  }

  bool get isRunning => _server != null;

  Future<void> _ensureServer() {
    return _starting ??= _bind().whenComplete(() => _starting = null);
  }

  Future<void> _bind() async {
    if (_server != null) {
      return;
    }
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen(_handle, onError: (_) {}, cancelOnError: false);
  }

  /// 注册一个 SMB 对象并返回可交给播放器的 URL
  Future<String> serve(SmbTarget target) async {
    await _ensureServer();
    final token =
        '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
        '${(_seq++).toRadixString(36)}'
        '${target.host.hashCode.abs().toRadixString(36)}';
    _targets[token] = target;
    // 只保留最近的若干映射, 避免长时间运行累积
    while (_targets.length > 64) {
      _targets.remove(_targets.keys.first);
    }
    return '${baseUrl!}/s/$token';
  }

  Future<void> close() async {
    _targets.clear();
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      final segments = request.uri.pathSegments;
      if (segments.length != 2 || segments[0] != 's') {
        await _fail(request, HttpStatus.notFound, 'not found');
        return;
      }
      final target = _targets[segments[1]];
      if (target == null) {
        await _fail(request, HttpStatus.notFound, 'unknown token');
        return;
      }
      await _serve(request, target);
    } catch (_) {
      await _fail(request, HttpStatus.badGateway, 'proxy error');
    }
  }

  Future<void> _serve(HttpRequest request, SmbTarget target) async {
    final client = Smb2Client(host: target.host, port: target.port);
    try {
      await client.connect(
        user: target.user,
        password: target.password,
        domain: target.domain,
      );
      await client.treeConnect(target.share);
      final handle = await client.openFile(target.path);
      final total = handle.size;
      final range = parseRange(request.headers.value(HttpHeaders.rangeHeader), total);
      final start = range.$1;
      final end = range.$2;
      final length = end < start ? 0 : end - start + 1;

      final response = request.response;
      response.headers
        ..set(HttpHeaders.acceptRangesHeader, 'bytes')
        ..contentType = _contentType(target.path)
        ..contentLength = length;

      if (request.method == 'HEAD') {
        response.statusCode = HttpStatus.ok;
        await response.close();
        return;
      }

      final partial = !(start == 0 && end == total - 1);
      response.statusCode = partial
          ? HttpStatus.partialContent
          : HttpStatus.ok;
      if (partial) {
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/$total',
        );
      }

      var offset = start;
      while (offset <= end) {
        final want = min(end - offset + 1, chunkSize);
        final data = await client.read(
          handle.persistent,
          handle.volatile,
          offset,
          want,
        );
        if (data.isEmpty) {
          break;
        }
        response.add(data);
        await response.flush();
        offset += data.length;
      }
      await response.close();
    } on SmbException catch (e) {
      await _fail(
        request,
        e.isNotFound ? HttpStatus.notFound : HttpStatus.badGateway,
        e.statusText,
      );
    } finally {
      await client.close();
    }
  }

  Future<void> _fail(HttpRequest request, int status, String message) async {
    try {
      final response = request.response;
      if (response.headers.contentLength < 0) {
        response
          ..statusCode = status
          ..headers.contentType = ContentType.text;
        response.write(message);
      }
      await response.close();
    } catch (_) {
      // 客户端已断开
    }
  }

  static ContentType _contentType(String path) {
    final dot = path.lastIndexOf('.');
    final ext = dot < 0 ? '' : path.substring(dot + 1).toLowerCase();
    return switch (ext) {
      'mp4' || 'm4v' || 'mov' => ContentType('video', 'mp4'),
      'mkv' || 'webm' => ContentType('video', 'x-matroska'),
      'ts' || 'm2ts' || 'mts' => ContentType('video', 'mp2t'),
      'avi' => ContentType('video', 'x-msvideo'),
      'flac' => ContentType('audio', 'flac'),
      'mp3' => ContentType('audio', 'mpeg'),
      _ => ContentType('application', 'octet-stream'),
    };
  }

  /// 解析 Range 头, 返回闭区间 [start, end]; 无 Range 时返回整个文件。
  /// 单独暴露出来是为了做纯逻辑单元测试。
  static (int, int) parseRange(String? header, int total) {
    if (total <= 0) {
      return (0, -1);
    }
    if (header == null || !header.startsWith('bytes=')) {
      return (0, total - 1);
    }
    final spec = header.substring(6).trim();
    final dash = spec.indexOf('-');
    if (dash < 0) {
      return (0, total - 1);
    }
    final startText = spec.substring(0, dash).trim();
    final endText = spec.substring(dash + 1).trim();
    if (startText.isEmpty) {
      // bytes=-N: 最后 N 字节
      final suffix = int.tryParse(endText);
      if (suffix == null || suffix <= 0) {
        return (0, total - 1);
      }
      final start = total - suffix;
      return (start < 0 ? 0 : start, total - 1);
    }
    final start = int.tryParse(startText);
    if (start == null || start < 0 || start >= total) {
      return (0, total - 1);
    }
    final parsedEnd = endText.isEmpty ? null : int.tryParse(endText);
    final end = parsedEnd == null || parsedEnd > total - 1
        ? total - 1
        : parsedEnd;
    return (start, end < start ? start : end);
  }
}
