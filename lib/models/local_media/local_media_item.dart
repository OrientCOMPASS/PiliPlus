import 'dart:convert' show utf8;

import 'package:PiliPlus/models/local_media/local_media_source.dart';
import 'package:archive/archive.dart' show getCrc32;

/// 扩展名白名单。
///
/// 只列出安卓端打包的 FFmpeg **确实启用了对应 demuxer** 的容器:
/// mov(mp4/m4v/mov/3gp)、matroska(mkv/webm)、avi、mpegts(ts/m2ts/mts)、
/// flv、mpegps(mpg/mpeg/vob)、asf(wmv/asf)、hls(m3u8)。
/// 未启用的容器(如 rmvb、ogv)即使列出来也播不了, 因此不放进白名单。
abstract final class LocalMediaExtensions {
  static const Set<String> videos = {
    'mp4',
    'm4v',
    'mov',
    'mkv',
    'webm',
    'avi',
    'ts',
    'm2ts',
    'mts',
    'flv',
    'mpg',
    'mpeg',
    'vob',
    'wmv',
    'asf',
    '3gp',
    '3g2',
    'm3u8',
  };

  static const Set<String> audios = {
    'mp3',
    'flac',
    'm4a',
    'aac',
    'wav',
    'ape',
    'wv',
    'tta',
    'tak',
    'dsf',
    'aiff',
    'au',
  };

  static const Set<String> subtitles = {
    'srt',
    'ass',
    'ssa',
    'vtt',
    'stl',
    'sub',
  };
}

/// 「本地」板块中的一条记录: 目录、视频或音频文件。
class LocalMediaItem {
  const LocalMediaItem({
    required this.name,
    required this.uri,
    required this.source,
    this.remotePath,
    this.size,
    this.modified,
    this.isDirectory = false,
  });

  /// 显示名(文件名或目录名)
  final String name;

  /// 可直接交给播放器的地址: 本机为绝对路径, 网络来源为完整 URL
  final String uri;

  final LocalMediaSource source;

  /// 网络来源在服务器上的路径, 用于继续浏览与拼接播放地址
  final String? remotePath;

  final int? size;
  final DateTime? modified;
  final bool isDirectory;

  String get extension {
    final dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) {
      return '';
    }
    return name.substring(dot + 1).toLowerCase();
  }

  bool get isVideo => LocalMediaExtensions.videos.contains(extension);

  bool get isAudio => LocalMediaExtensions.audios.contains(extension);

  bool get isSubtitle => LocalMediaExtensions.subtitles.contains(extension);

  /// 稳定的数字 id(crc32)。只用于 heroTag / GetX tag 这类需要 int 的地方,
  /// 不会发给任何接口。
  int get cid => getCrc32(utf8.encode(uri));

  /// 可播放(目录不可播放)
  bool get isPlayable => !isDirectory && (isVideo || isAudio);

  LocalMediaItem copyWith({String? uri, DateTime? modified, int? size}) =>
      LocalMediaItem(
        name: name,
        uri: uri ?? this.uri,
        source: source,
        remotePath: remotePath,
        size: size ?? this.size,
        modified: modified ?? this.modified,
        isDirectory: isDirectory,
      );

  @override
  bool operator ==(Object other) => other is LocalMediaItem && other.uri == uri;

  @override
  int get hashCode => uri.hashCode;

  @override
  String toString() => 'LocalMediaItem($name, $uri)';
}
