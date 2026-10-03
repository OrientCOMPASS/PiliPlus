import 'dart:convert' show utf8;

import 'package:PiliPlus/models/local_media/local_media_source.dart';
import 'package:archive/archive.dart' show getCrc32;

/// 扩展名白名单。
///
/// 只列出安卓端打包的 FFmpeg **确实启用了对应 demuxer** 的容器:
/// mov(mp4/m4v/mov/3gp/f4v/insv)、matroska(mkv/webm)、avi、
/// mpegts(ts/m2ts/mts/m2t/tp)、flv、mpegps(mpg/mpeg/vob/m1v/m2v)、
/// asf(wmv/asf)、hls(m3u8)、裸 hevc 流(h265/hevc/265)。
/// 未启用的容器(如 rmvb、ogv)即使列出来也播不了, 因此不放进白名单。
/// 扩展名不在名单里不代表播不了——mpv 按**内容**探测打开文件, 本机来源
/// 对大文件还做了文件头嗅探兜底(见 `LocalMediaService.sniffVideoHeader`)。
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
    'm2t',
    'tp',
    'flv',
    'f4v',
    'mpg',
    'mpeg',
    'm1v',
    'm2v',
    'vob',
    'wmv',
    'asf',
    '3gp',
    '3g2',
    'm3u8',
    // VR/全景设备与裸流: Insta360 的 .insv 就是 mov 容器;
    // 裸 HEVC 流(demuxer=hevc 已启用)常见于相机/录屏导出
    'insv',
    'h265',
    'hevc',
    '265',
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

  /// 从文件名提取扩展名(小写、不带点); 没有扩展名返回空串
  static String of(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) {
      return '';
    }
    return name.substring(dot + 1).toLowerCase();
  }

  /// 扩展名是否属于任一已知媒体类别(视频/音频/字幕)。
  /// 未知扩展名(或没有扩展名)的**大文件**会走文件头嗅探兜底,
  /// 避免 VR 片源这类非常规命名的视频被静默过滤。
  static bool known(String ext) =>
      videos.contains(ext) || audios.contains(ext) || subtitles.contains(ext);
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
    this.probedVideo = false,
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

  /// 扩展名不在白名单(或没有扩展名), 但**文件头嗅探**确认是视频容器。
  /// mpv 按内容探测打开文件, 扩展名只是列表过滤的便捷判据——不该成为
  /// 非常规命名片源(如 VR 素材)被静默丢弃的理由。仅本机来源会嗅探。
  final bool probedVideo;

  String get extension => LocalMediaExtensions.of(name);

  bool get isVideo =>
      probedVideo || LocalMediaExtensions.videos.contains(extension);

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
        probedVideo: probedVideo,
      );

  @override
  bool operator ==(Object other) => other is LocalMediaItem && other.uri == uri;

  @override
  int get hashCode => uri.hashCode;

  @override
  String toString() => 'LocalMediaItem($name, $uri)';
}
