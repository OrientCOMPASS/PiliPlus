import 'package:PiliPlus/models/local_media/vr_format.dart';
import 'package:flutter_test/flutter_test.dart';

/// VR 格式识别/映射的纯逻辑回归测试(渲染在定制 libvlc 补丁内, 见
/// tool/libvlc-vr 与 docs/piliplayer.md §18; 用例移植自 mpv VR 时代验证过
/// 的 test/plugin/vr_test.dart)。
void main() {
  group('VrFormat.detectFromName', () {
    VrFormat? detect(String name) => VrFormat.detectFromName(name);

    test('明确的左右/上下 + 360/180', () {
      expect(detect('movie.sbs.360.mkv'), VrFormat.sbs360);
      expect(detect('movie_sbs_180.mkv'), VrFormat.sbs180);
      expect(detect('movie TB 360.mp4'), VrFormat.tb360);
      expect(detect('movie.ou.180.mp4'), VrFormat.tb180);
      expect(detect('左右格式3D.mkv'), VrFormat.sbs360);
      expect(detect('上下格式180.mkv'), VrFormat.tb180);
    });

    test('等距柱状(无立体标记)', () {
      expect(detect('panorama_360.mp4'), VrFormat.e360);
      expect(detect('VR180.mkv'), VrFormat.e180);
      expect(detect('全景视频.mp4'), VrFormat.e360);
      expect(detect('equirectangular.mp4'), VrFormat.e360);
    });

    test('清晰度数字不能被误判成全景', () {
      // 360p / 1080p / 2160p 都是清晰度写法
      expect(detect('video.360p.mp4'), isNull);
      expect(detect('video.1080p.mkv'), isNull);
      expect(detect('[1080P]普通视频.mp4'), isNull);
      expect(detect('normal_video.mp4'), isNull);
    });

    test('只有 3d 字样时不乱猜布局', () {
      expect(detect('some.3d.movie.mkv'), isNull);
    });
  });

  group('VrFormat 属性与桥映射', () {
    test('coverageH / isStereo / forcesImmersive', () {
      expect(VrFormat.e360.coverageH, 360.0);
      expect(VrFormat.tb180.coverageH, 180.0);
      expect(VrFormat.sbs360.isStereo, isTrue);
      expect(VrFormat.tb360.isStereo, isTrue);
      expect(VrFormat.e360.isStereo, isFalse);
      expect(VrFormat.auto.forcesImmersive, isFalse);
      expect(VrFormat.off.forcesImmersive, isFalse);
      expect(VrFormat.e180.forcesImmersive, isTrue);
    });

    test('bridgeMode 与 Kotlin VlcPlayerBridge 的 vrMode 约定一致', () {
      // 0=auto 1=off 2=360 3=360SBS 4=360TB 5=180 6=180SBS 7=180TB
      expect(VrFormat.auto.bridgeMode, 0);
      expect(VrFormat.off.bridgeMode, 1);
      expect(VrFormat.e360.bridgeMode, 2);
      expect(VrFormat.sbs360.bridgeMode, 3);
      expect(VrFormat.tb360.bridgeMode, 4);
      expect(VrFormat.e180.bridgeMode, 5);
      expect(VrFormat.sbs180.bridgeMode, 6);
      expect(VrFormat.tb180.bridgeMode, 7);
      expect(VrFormat.values.length, 8);
    });
  });
}
