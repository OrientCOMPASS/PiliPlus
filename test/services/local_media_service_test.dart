import 'package:PiliPlus/models/local_media/local_media_item.dart';
import 'package:PiliPlus/models/local_media/local_media_sort.dart';
import 'package:PiliPlus/models/local_media/local_media_source.dart';
import 'package:PiliPlus/pages/local_media/controller.dart';
import 'package:PiliPlus/services/local_media_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「本地」板块服务层的纯函数测试: 地址拼接、脱敏、排序、扩展名白名单,
/// 以及第四轮新增的「添加到快捷方式」(VLC 式书签)的地址推导。
void main() {
  const device = LocalMediaSource(
    type: LocalMediaSourceType.device,
    name: '本机存储',
    url: '/storage/emulated/0',
  );
  const smbHost = LocalMediaSource(
    type: LocalMediaSourceType.smb,
    name: 'NAS',
    url: 'smb://NAS',
    username: 'u',
    password: 'p',
    address: '192.168.1.5',
  );
  const smbShare = LocalMediaSource(
    type: LocalMediaSourceType.smb,
    name: 'pub',
    url: 'smb://NAS/pub',
    username: 'u',
    password: 'p',
  );
  const dav = LocalMediaSource(
    type: LocalMediaSourceType.webdav,
    name: 'dav',
    url: 'https://nas.example.com/dav',
    username: 'u',
    password: 'p',
  );

  group('joinUrl', () {
    test('逐段编码, 中文/空格不会让服务端 404', () {
      expect(
        LocalMediaService.joinUrl('https://h/dav', 'videos/第 1集.mkv'),
        'https://h/dav/videos/%E7%AC%AC%201%E9%9B%86.mkv',
      );
    });

    test('已经编码过的段不会被二次编码成 %25', () {
      expect(
        LocalMediaService.joinUrl('https://h/dav', 'a%20b.mp4'),
        'https://h/dav/a%20b.mp4',
      );
    });

    test('基址末尾有斜杠也不会出现双斜杠', () {
      expect(
        LocalMediaService.joinUrl('https://h/dav/', 'x.mp4'),
        'https://h/dav/x.mp4',
      );
    });
  });

  group('playbackUrl', () {
    test('本机文件直接用绝对路径', () {
      const item = LocalMediaItem(
        name: 'a.mp4',
        uri: '/storage/emulated/0/a.mp4',
        source: device,
      );
      expect(LocalMediaService.playbackUrl(item), '/storage/emulated/0/a.mp4');
    });

    test('网络条目已经是完整 URL 时原样返回', () {
      const item = LocalMediaItem(
        name: 'a.mp4',
        uri: 'http://127.0.0.1:1234/s/token',
        source: smbHost,
      );
      expect(
        LocalMediaService.playbackUrl(item),
        'http://127.0.0.1:1234/s/token',
      );
    });
  });

  group('maskedUrl', () {
    test('密码不外泄', () {
      expect(
        LocalMediaService.maskedUrl('https://u:secret@h/dav/a.mp4'),
        'https://u:***@h/dav/a.mp4',
      );
      expect(LocalMediaService.maskedUrl('/sdcard/a.mp4'), '/sdcard/a.mp4');
      expect(
        LocalMediaService.maskedUrl('smb://NAS/pub/a.mp4'),
        'smb://NAS/pub/a.mp4',
      );
    });
  });

  group('扩展名白名单', () {
    test('只放打包的 FFmpeg 确实能解封装的容器', () {
      expect(LocalMediaExtensions.videos, containsAll(['mp4', 'mkv', 'ts']));
      // rmvb / ogv 没有对应 demuxer, 显示出来也播不了
      expect(LocalMediaExtensions.videos, isNot(contains('rmvb')));
      expect(LocalMediaExtensions.videos, isNot(contains('ogv')));
    });

    test('条目类型判定', () {
      LocalMediaItem item(String name) =>
          LocalMediaItem(name: name, uri: name, source: device);
      expect(item('a.MP4').isVideo, isTrue);
      expect(item('a.flac').isAudio, isTrue);
      expect(item('a.srt').isSubtitle, isTrue);
      expect(item('a.srt').isPlayable, isFalse);
      expect(item('a.txt').isPlayable, isFalse);
      expect(item('noext').extension, '');
      expect(
        const LocalMediaItem(
          name: 'dir',
          uri: '/dir',
          source: device,
          isDirectory: true,
        ).isPlayable,
        isFalse,
      );
    });

    test('cid 只由 uri 决定(用于本机续播进度的 key, 不发接口)', () {
      const a = LocalMediaItem(
        name: 'x.mp4',
        uri: 'smb://NAS/pub/x.mp4',
        source: smbShare,
      );
      const b = LocalMediaItem(
        name: '别的名字',
        uri: 'smb://NAS/pub/x.mp4',
        source: smbShare,
      );
      expect(a.cid, b.cid);
      expect(a, b); // 相等性只看 uri
    });
  });

  group('sortItems', () {
    LocalMediaItem item(
      String name, {
      bool dir = false,
      int? size,
      DateTime? modified,
    }) => LocalMediaItem(
      name: name,
      uri: '${dir ? 'd' : 'f'}://$name',
      source: device,
      size: size,
      modified: modified,
      isDirectory: dir,
    );

    test('目录永远在前', () {
      final sorted = LocalMediaService.sortItems(
        [item('b.mp4'), item('aaa', dir: true)],
        LocalMediaSort.name,
      );
      expect(sorted.first.isDirectory, isTrue);
    });

    test('自然排序: 第2集 在 第10集 前面', () {
      final sorted = LocalMediaService.sortItems(
        [item('第10集.mp4'), item('第2集.mp4'), item('第1集.mp4')],
        LocalMediaSort.name,
      );
      expect(
        sorted.map((e) => e.name).toList(),
        ['第1集.mp4', '第2集.mp4', '第10集.mp4'],
      );
    });

    test('按大小/修改时间排序', () {
      final bySize = LocalMediaService.sortItems(
        [item('a', size: 1), item('b', size: 3), item('c', size: 2)],
        LocalMediaSort.size,
      );
      expect(bySize.map((e) => e.name).toList(), ['b', 'c', 'a']);

      final byTime = LocalMediaService.sortItems(
        [
          item('a', modified: DateTime(2020)),
          item('b', modified: DateTime(2024)),
          item('c', modified: DateTime(2022)),
        ],
        LocalMediaSort.modified,
      );
      expect(byTime.map((e) => e.name).toList(), ['b', 'c', 'a']);
    });

    test('不改动传入的列表', () {
      final input = [item('b'), item('a')];
      LocalMediaService.sortItems(input, LocalMediaSort.name);
      expect(input.map((e) => e.name).toList(), ['b', 'a']);
    });
  });

  group('shortcutFor(添加到快捷方式)', () {
    test('本机目录: url 就是绝对路径', () {
      final s = LocalMediaController.shortcutFor(
        source: device,
        path: '/storage/emulated/0/Movies',
        title: 'Movies',
      );
      expect(s, isNotNull);
      expect(s!.type, LocalMediaSourceType.device);
      expect(s.name, 'Movies');
      expect(s.url, '/storage/emulated/0/Movies');
    });

    test('主机级 SMB: 路径第一段是共享名, 凭据与兜底 IP 一起带上', () {
      final s = LocalMediaController.shortcutFor(
        source: smbHost,
        path: r'pub\videos',
        title: 'videos',
      );
      expect(s!.url, 'smb://NAS/pub/videos');
      expect(s.username, 'u');
      expect(s.password, 'p');
      expect(s.address, '192.168.1.5');
    });

    test('主机级 SMB 在主机根上没有可收藏的目录', () {
      expect(
        LocalMediaController.shortcutFor(
          source: smbHost,
          path: '',
          title: 'NAS',
        ),
        isNull,
      );
    });

    test('共享级 SMB: 共享名来自来源, 路径是共享内相对路径', () {
      final s = LocalMediaController.shortcutFor(
        source: smbShare,
        path: r'videos\2024',
        title: '2024',
      );
      expect(s!.url, 'smb://NAS/pub/videos/2024');
    });

    test('WebDAV: 基址 + 路径', () {
      final s = LocalMediaController.shortcutFor(
        source: dav,
        path: '/videos',
        title: 'videos',
      );
      expect(s!.url, 'https://nas.example.com/dav/videos');
      expect(s.username, 'u');
    });

    test('直链来源与来源根目录不可收藏', () {
      const http = LocalMediaSource(
        type: LocalMediaSourceType.http,
        name: 'h',
        url: 'http://a/b.mp4',
      );
      expect(
        LocalMediaController.shortcutFor(source: http, path: '', title: 'h'),
        isNull,
      );
      expect(
        LocalMediaController.shortcutFor(source: dav, path: '/', title: 'dav'),
        isNull,
      );
    });

    test('标题为空时退回来源名', () {
      final s = LocalMediaController.shortcutFor(
        source: device,
        path: '/storage/emulated/0/Movies',
        title: '',
      );
      expect(s!.name, device.name);
    });
  });
}
