import 'package:PiliPlus/models/local_media/vlc_media.dart';
import 'package:flutter_test/flutter_test.dart';

/// VLC 本地媒体模型的纯逻辑测试(第十二轮: 本地板块整体切换到 libvlc,
/// 见 docs/piliplayer.md §17)。
void main() {
  group('VlcMediaItem', () {
    test('fromMap 容错: 缺字段退默认值', () {
      final item = VlcMediaItem.fromMap(const {'id': 3, 'title': 'a'});
      expect(item.id, 3);
      expect(item.title, 'a');
      expect(item.uri, '');
      expect(item.lengthMs, 0);
      expect(item.timeMs, 0);
    });

    test('folderPath/folderName: file URI 与裸路径都取父目录', () {
      const a = VlcMediaItem(
        id: 1,
        title: 'x',
        uri: 'file:///storage/emulated/0/Movies/VR/x.mp4',
      );
      expect(a.filePath, '/storage/emulated/0/Movies/VR/x.mp4');
      expect(a.folderPath, '/storage/emulated/0/Movies/VR');
      expect(a.folderName, 'VR');
      const b = VlcMediaItem(id: 2, title: 'y', uri: '/sdcard/Download/y.mkv');
      expect(b.folderPath, '/sdcard/Download');
      expect(b.folderName, 'Download');
    });

    test('finished: 结尾前 10 秒内视为看完', () {
      const near = VlcMediaItem(
        id: 1,
        title: 't',
        uri: 'file:///a.mp4',
        lengthMs: 100000,
        timeMs: 95000,
      );
      expect(near.finished, isTrue);
      const mid = VlcMediaItem(
        id: 1,
        title: 't',
        uri: 'file:///a.mp4',
        lengthMs: 100000,
        timeMs: 50000,
      );
      expect(mid.finished, isFalse);
      // 没看过不算看完
      const fresh = VlcMediaItem(id: 1, title: 't', uri: 'file:///a.mp4');
      expect(fresh.finished, isFalse);
    });

    test('displayName: 标题缺失退回文件名/URI', () {
      const a = VlcMediaItem(id: 1, title: '', uri: 'file:///a.mp4');
      expect(a.displayName, 'file:///a.mp4');
      const b = VlcMediaItem(
        id: 1,
        title: '',
        uri: 'file:///a.mp4',
        fileName: 'a.mp4',
      );
      expect(b.displayName, 'a.mp4');
    });
  });

  group('VlcBrowseItem', () {
    test('目录不可播, 文件都可交给 libvlc 去试', () {
      const dir = VlcBrowseItem(name: 'd', uri: 'smb://h/s/d/', isDir: true);
      expect(dir.isPlayable, isFalse);
      const ogv = VlcBrowseItem(name: 'v', uri: 'smb://h/s/d/v.ogv');
      // 旧实现的扩展名白名单已废弃: VLC 支持的格式远比打包 FFmpeg 宽
      expect(ogv.isPlayable, isTrue);
    });
  });

  group('VlcSavedShare', () {
    test('maskedUri 隐藏 userinfo 里的密码', () {
      const s = VlcSavedShare(
        name: 'nas',
        uri: 'smb://user:p%40ss@192.168.1.5/share',
      );
      expect(s.maskedUri, isNot(contains('p%40ss')));
      expect(s.maskedUri, contains('***@'));
      const anon = VlcSavedShare(name: 'a', uri: 'smb://192.168.1.5/share');
      expect(anon.maskedUri, anon.uri);
    });
  });
}
