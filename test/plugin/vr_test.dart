import 'package:PiliPlus/plugin/pl_player/models/vr_projection.dart';
import 'package:flutter_test/flutter_test.dart';

/// VR / 全景相关纯逻辑的回归测试。
///
/// VR 重投影已移入定制 libmpv(见 tool/libmpv-vr 与 docs/piliplayer.md §15),
/// Dart 侧只剩"片源识别 + 元数据解析 + 视角状态 + mpv 属性值映射"这些纯逻辑,
/// 渲染数学(球面网格/畸变网格/EKF)在 mpv 补丁内, 由 CI 编译与真机验证。
/// 需求矩阵与收敛规则见仓库根目录 REQUIREMENTS.md。
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
      expect(detect('Over-Under 3D 180.mp4'), VrProjection.tb180);
      expect(detect('某某全景.mp4'), VrProjection.equirect360);
      expect(detect('panoramic tour.mp4'), VrProjection.equirect360);
    });

    test('等距柱状(无立体标记)', () {
      expect(detect('panorama_360.mp4'), VrProjection.equirect360);
      expect(detect('VR180.mkv'), VrProjection.equirect180);
      expect(detect('全景视频.mp4'), VrProjection.equirect360);
      expect(detect('equirectangular.mp4'), VrProjection.equirect360);
    });

    test('清晰度数字不能被误判成全景', () {
      // 360p / 1080p / 2160p 都是清晰度写法: 不当全景, 也不当"识别到",
      // 按需求第 5 条回退「自动(元数据)」
      expect(detect('video.360p.mp4'), VrProjection.auto);
      expect(detect('video.1080p.mkv'), VrProjection.auto);
      expect(detect('[1080P]普通视频.mp4'), VrProjection.auto);
      expect(detect('normal_video.mp4'), VrProjection.auto);
    });

    test('只有 3d 字样时不乱猜布局, 回退元数据', () {
      expect(detect('some.3d.movie.mkv'), VrProjection.auto);
    });

    test('coverageH / isStereo / isSideBySide / enabled', () {
      expect(VrProjection.equirect360.coverageH, 360.0);
      expect(VrProjection.tb180.coverageH, 180.0);
      expect(VrProjection.sbs360.isStereo, isTrue);
      expect(VrProjection.sbs360.isSideBySide, isTrue);
      expect(VrProjection.tb360.isStereo, isTrue);
      expect(VrProjection.tb360.isSideBySide, isFalse);
      expect(VrProjection.equirect360.isStereo, isFalse);
      expect(VrProjection.off.enabled, isFalse);
      // auto 是"待解析"状态, 解析前按平面播放, 不算生效
      expect(VrProjection.auto.enabled, isFalse);
      expect(VrProjection.equirect360.enabled, isTrue);
    });

    test('180 片源的偏航角要收敛, 避免转出画面出现黑边', () {
      expect(VrProjection.equirect180.yawRange(90), (min: -45.0, max: 45.0));
      expect(VrProjection.tb180.yawRange(60), (min: -60.0, max: 60.0));
      expect(VrProjection.equirect360.yawRange(90), (min: -180.0, max: 180.0));
    });
  });

  group('VrProjection.resolveMetadata (自动: 按片源元数据)', () {
    VrAutoResolution resolve(String projection, String layout) =>
        VrProjection.resolveMetadata(projection: projection, layout: layout);

    test('等距柱状 × 立体布局 的完整矩阵', () {
      expect(resolve('360', 'none').projection, VrProjection.equirect360);
      expect(resolve('360', 'mono').projection, VrProjection.equirect360);
      expect(resolve('360', 'sbs').projection, VrProjection.sbs360);
      expect(resolve('360', 'tb').projection, VrProjection.tb360);
      expect(resolve('180', 'none').projection, VrProjection.equirect180);
      expect(resolve('180', 'mono').projection, VrProjection.equirect180);
      expect(resolve('180', 'sbs').projection, VrProjection.sbs180);
      expect(resolve('180', 'tb').projection, VrProjection.tb180);
      for (final r in [
        resolve('360', 'sbs'),
        resolve('180', 'tb'),
        resolve('360', 'none'),
      ]) {
        expect(r.isVr, isTrue);
        expect(r.unsupportedReason, isNull);
      }
    });

    test('没有元数据 -> 平面, 无需提示', () {
      final r = resolve('none', 'none');
      expect(r.isVr, isFalse);
      expect(r.projection, VrProjection.off);
      expect(r.unsupportedReason, isNull);
    });

    test('范围外格式必须给出明确提示(不得静默失效)', () {
      // cubemap 片源: 需求第 9 条明确不做
      final cubemap = resolve('cubemap', 'none');
      expect(cubemap.isVr, isFalse);
      expect(cubemap.unsupportedReason, contains('cubemap'));
      // 其他投影(鱼眼/矩形/沉浸式)
      expect(resolve('other', 'none').unsupportedReason, isNotNull);
      // 棋盘格等立体排布
      expect(resolve('360', 'other').unsupportedReason, isNotNull);
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

    test('俯仰角在极点收敛: 视口垂直方向不能转出等距柱状图', () {
      // 横屏视口(aspect 2.0), fov 90 -> vfov = 2*atan(tan45°/2) ≈ 53.1
      // -> 俯仰上限 ≈ 63.4
      final landscape = const VrViewState(pitch: 89).clamped(
        VrProjection.equirect360,
        aspect: 2.0,
      );
      final limit = VrViewState.pitchLimit(90, 2.0);
      expect(landscape.pitch, closeTo(limit, 1e-9));
      expect(landscape.pitch, closeTo(63.4, 0.1));
      expect(landscape.pitch, lessThan(VrViewState.maxPitch));
      // 与 mpv vr_fovy_from_hfov 同一公式: vfov = 2*atan(tan(h/2)/aspect)
      expect(VrViewState.verticalFov(90, 2.0), closeTo(53.1, 0.1));
      // aspect 1.0 时垂直视场 == 水平视场
      expect(VrViewState.verticalFov(90, 1.0), closeTo(90, 1e-9));
    });

    test('俯仰角与视场角夹紧(aspect 未知时按 1.0 保守收敛)', () {
      final s = const VrViewState(pitch: 120, fov: 999).clamped(
        VrProjection.equirect360,
      );
      // fov 999 -> maxFov 120; aspect null -> vfov 120 -> 俯仰上限 30
      expect(s.fov, VrViewState.maxFov);
      expect(s.pitch, closeTo(VrViewState.pitchLimit(120, null), 1e-9));
      expect(s.pitch, closeTo(30.0, 1e-9));
    });

    test('陀螺仪模式放宽收敛(需求第 3 条)', () {
      // 180° 片源手动模式偏航上限 45(fov 90), 陀螺仪模式只回绕不夹取
      final manual = const VrViewState(yaw: 80).clamped(
        VrProjection.equirect180,
        aspect: 2.0,
      );
      expect(manual.yaw, 45.0);
      final gyro = const VrViewState(yaw: 80).clamped(
        VrProjection.equirect180,
        aspect: 2.0,
        gyro: true,
      );
      expect(gyro.yaw, 80.0);
      // 俯仰放宽到 ±maxPitch
      final gyroPitch = const VrViewState(pitch: 88).clamped(
        VrProjection.equirect360,
        aspect: 2.0,
        gyro: true,
      );
      expect(gyroPitch.pitch, 88.0);
    });

    test('fov 变化后 180 片源的偏航上限随之收敛', () {
      // fov 120 -> 上限 (180-120)/2 = 30, 之前的 45 也要被拉回
      final s = const VrViewState(yaw: 45, fov: 120).clamped(
        VrProjection.equirect180,
      );
      expect(s.yaw, 30.0);
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
