import 'package:PiliPlus/plugin/pl_player/models/vr_projection.dart';
import 'package:flutter_test/flutter_test.dart';

/// VR / 全景相关纯逻辑的回归测试。
///
/// VR 重投影已移入定制 libmpv(见 tool/libmpv-vr 与 docs/piliplayer.md §15),
/// Dart 侧只剩"片源识别 + 视角状态 + mpv 属性值映射"这些纯逻辑,
/// 渲染数学(球面网格/畸变网格/EKF)在 mpv 补丁内, 由 CI 编译与真机验证。
void main() {
  group('VrProjection.detectFromName', () {
    VrProjection detect(String name) => VrProjection.detectFromName(name);

    test('明确的左右/上下 + 360/180', () {
      expect(detect('movie.sbs.360.mkv'), VrProjection.sbs360);
      expect(detect('movie_sbs_180.mkv'), VrProjection.sbs180);
      expect(detect('movie TB 360.mp4'), VrProjection.tb360);
      expect(detect('movie.ou.180.mp4'), VrProjection.tb180);
      expect(detect('左右格式3D.mkv'), VrProjection.sbs360);
      expect(detect('上下格式180.mkv'), VrProjection.tb180);
    });

    test('等距柱状(无立体标记)', () {
      expect(detect('panorama_360.mp4'), VrProjection.equirect360);
      expect(detect('VR180.mkv'), VrProjection.equirect180);
      expect(detect('全景视频.mp4'), VrProjection.equirect360);
      expect(detect('equirectangular.mp4'), VrProjection.equirect360);
    });

    test('清晰度数字不能被误判成全景', () {
      // 360p / 1080p / 2160p 都是清晰度写法
      expect(detect('video.360p.mp4'), VrProjection.off);
      expect(detect('video.1080p.mkv'), VrProjection.off);
      expect(detect('[1080P]普通视频.mp4'), VrProjection.off);
      expect(detect('normal_video.mp4'), VrProjection.off);
    });

    test('只有 3d 字样时不乱猜布局', () {
      expect(detect('some.3d.movie.mkv'), VrProjection.off);
    });

    test('coverageH / isStereo / isSideBySide', () {
      expect(VrProjection.equirect360.coverageH, 360.0);
      expect(VrProjection.tb180.coverageH, 180.0);
      expect(VrProjection.sbs360.isStereo, isTrue);
      expect(VrProjection.sbs360.isSideBySide, isTrue);
      expect(VrProjection.tb360.isStereo, isTrue);
      expect(VrProjection.tb360.isSideBySide, isFalse);
      expect(VrProjection.equirect360.isStereo, isFalse);
      expect(VrProjection.off.enabled, isFalse);
    });

    test('180 片源的偏航角要收敛, 避免转出画面出现黑边', () {
      expect(VrProjection.equirect180.yawRange(90), (min: -45.0, max: 45.0));
      expect(VrProjection.tb180.yawRange(60), (min: -60.0, max: 60.0));
      expect(VrProjection.equirect360.yawRange(90), (min: -180.0, max: 180.0));
    });
  });

  group('VrProjection -> mpv 属性值映射', () {
    test('vr-layout: 单目/左右/上下', () {
      expect(VrProjection.equirect360.mpvLayout, 'mono');
      expect(VrProjection.equirect180.mpvLayout, 'mono');
      expect(VrProjection.sbs360.mpvLayout, 'sbs');
      expect(VrProjection.sbs180.mpvLayout, 'sbs');
      expect(VrProjection.tb360.mpvLayout, 'tb');
      expect(VrProjection.tb180.mpvLayout, 'tb');
    });

    test('vr-projection: 水平覆盖角', () {
      expect(VrProjection.equirect360.mpvCoverage, '360');
      expect(VrProjection.sbs360.mpvCoverage, '360');
      expect(VrProjection.tb360.mpvCoverage, '360');
      expect(VrProjection.equirect180.mpvCoverage, '180');
      expect(VrProjection.sbs180.mpvCoverage, '180');
      expect(VrProjection.tb180.mpvCoverage, '180');
    });
  });

  group('VrViewState', () {
    test('360 片源偏航角回绕, 180 片源夹紧', () {
      final wrapped = const VrViewState(yaw: 190).clamped(
        VrProjection.equirect360,
      );
      expect(wrapped.yaw, closeTo(-170, 1e-9));

      final clamped = const VrViewState(yaw: 190).clamped(
        VrProjection.equirect180,
      );
      // fov 默认 90 -> 上限 (180-90)/2 = 45
      expect(clamped.yaw, 45.0);
    });

    test('俯仰角与视场角夹紧', () {
      final s = const VrViewState(pitch: 120, fov: 999).clamped(
        VrProjection.equirect360,
      );
      expect(s.pitch, VrViewState.maxPitch);
      expect(s.fov, VrViewState.maxFov);
    });

    test('copyWith 保持其余分量', () {
      const s = VrViewState(yaw: 10, pitch: -5, fov: 80);
      final t = s.copyWith(yaw: 20);
      expect(t.yaw, 20);
      expect(t.pitch, -5);
      expect(t.fov, 80);
    });
  });
}
