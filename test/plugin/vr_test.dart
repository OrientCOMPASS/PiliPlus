import 'dart:io';

import 'package:PiliPlus/plugin/pl_player/models/vr_projection.dart';
import 'package:PiliPlus/plugin/pl_player/utils/vr_shader.dart';
import 'package:PiliPlus/utils/path_utils.dart' show appSupportDirPath;
import 'package:flutter_test/flutter_test.dart';

/// VR / 全景相关纯逻辑的回归测试。
///
/// 重点覆盖第四轮真机问题的根因: **mpv 的 `vo=gpu` 按路径永久缓存用户着色器
/// 的文件内容**, 所以"改内容 + 同一路径重新下发"是无效的, 必须一次一个文件。
void main() {
  late Directory tempDir;

  setUpAll(() {
    tempDir = Directory.systemTemp.createTempSync('pili_vr_test');
    // path_utils 里的 appSupportDirPath 是 late final 全局量, 测试里指到临时目录,
    // 这样 VrShader 的写文件/清理也能真的跑起来
    appSupportDirPath = tempDir.path;
  });

  tearDownAll(() {
    VrShader.purge();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

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

    test('量化后等价 => sameRenderState', () {
      const a = VrViewState(yaw: 10.04, pitch: 0, fov: 90.1);
      const b = VrViewState(yaw: 10.0, pitch: 0, fov: 90.0);
      expect(a.sameRenderState(b, angleStep: 0.5, fovStep: 1.0), isTrue);
      expect(a.sameRenderState(b, angleStep: 0.01, fovStep: 0.01), isFalse);
    });
  });

  group('VrShader.eyeRect', () {
    test('单目片源取整幅画面', () {
      final r = VrShader.eyeRect(VrProjection.equirect360, VrEye.left);
      expect((r.u0, r.u1, r.v0, r.v1), (0.0, 1.0, 0.0, 1.0));
    });

    test('左右格式在 u 方向对半分', () {
      final left = VrShader.eyeRect(VrProjection.sbs360, VrEye.left);
      final right = VrShader.eyeRect(VrProjection.sbs360, VrEye.right);
      expect((left.u0, left.u1), (0.0, 0.5));
      expect((right.u0, right.u1), (0.5, 1.0));
      expect((left.v0, left.v1), (0.0, 1.0));
    });

    test('上下格式在 v 方向对半分', () {
      final left = VrShader.eyeRect(VrProjection.tb180, VrEye.left);
      final right = VrShader.eyeRect(VrProjection.tb180, VrEye.right);
      expect((left.v0, left.v1), (0.0, 0.5));
      expect((right.v0, right.v1), (0.5, 1.0));
      expect((left.u0, left.u1), (0.0, 1.0));
    });
  });

  group('VrShader.source', () {
    String src({
      VrProjection projection = VrProjection.equirect360,
      VrEye eye = VrEye.left,
      VrViewState view = const VrViewState(),
      double angleStep = 0.5,
      double fovStep = 1.0,
    }) => VrShader.source(
      projection: projection,
      eye: eye,
      view: view,
      angleStep: angleStep,
      fovStep: fovStep,
    );

    test('相同参数必须生成完全相同的源码(命中 mpv 程序缓存/Dart 侧映射)', () {
      expect(src(), src());
      expect(
        src(view: const VrViewState(yaw: 30, pitch: -10, fov: 80)),
        src(view: const VrViewState(yaw: 30, pitch: -10, fov: 80)),
      );
    });

    test('量化: 步长内的差异不产生新源码', () {
      expect(
        src(view: const VrViewState(yaw: 30.1)),
        src(view: const VrViewState(yaw: 30.2)),
      );
      expect(
        src(view: const VrViewState(yaw: 30.0)),
        isNot(src(view: const VrViewState(yaw: 31.0))),
      );
    });

    test('视角/布局/眼位都烘焙进了 #define', () {
      final s = src(
        projection: VrProjection.tb180,
        eye: VrEye.right,
        view: const VrViewState(yaw: 12.5, pitch: -30, fov: 75),
      );
      expect(s, contains('#define VR_YAW 12.500'));
      expect(s, contains('#define VR_PITCH -30.000'));
      expect(s, contains('#define VR_FOV 75.000'));
      expect(s, contains('#define VR_COVERAGE_H 180.000'));
      // 上下格式右眼: v 取下半幅
      expect(s, contains('#define VR_V0 0.500'));
      expect(s, contains('#define VR_V1 1.000'));
      expect(s, contains('//!HOOK MAIN'));
      expect(s, contains('//!DESC ${VrShader.passDesc}'));
    });

    test('展开格式不同 => 源码不同(这是"切格式不生效"的判定点)', () {
      final sources = <String>{
        for (final p in VrProjection.values.where((e) => e.enabled))
          src(projection: p),
      };
      expect(sources.length, VrProjection.values.length - 1);
    });
  });

  group('VrShader 文件槽位: 一个文件只写一次', () {
    test('序号不同 => 路径不同(mpv 按路径缓存内容, 复用路径会读到旧内容)', () {
      final paths = <String>{
        for (var i = 0; i < 64; i++) VrShader.fileNameFor(i),
      };
      expect(paths.length, 64);
      expect(VrShader.fileNameFor(0), startsWith(VrShader.filePrefix));
      expect(VrShader.fileNameFor(0), endsWith('.glsl'));
    });

    test('writeUnique 真的落盘且互不覆盖', () {
      final p0 = VrShader.writeUnique(1000, 'content-a');
      final p1 = VrShader.writeUnique(1001, 'content-b');
      expect(p0, isNot(p1));
      expect(File(p0).readAsStringSync(), 'content-a');
      expect(File(p1).readAsStringSync(), 'content-b');
      // 再写一个新序号不影响已写的两个
      VrShader.writeUnique(1002, 'content-c');
      expect(File(p0).readAsStringSync(), 'content-a');
      expect(File(p1).readAsStringSync(), 'content-b');
    });

    test('purge 只在播放器不存在时调用, 调用后目录消失', () {
      expect(Directory(VrShader.dirPath).existsSync(), isTrue);
      VrShader.purge();
      expect(Directory(VrShader.dirPath).existsSync(), isFalse);
      // purge 之后再写要能自动建目录
      final p = VrShader.writeUnique(2000, 'x');
      expect(File(p).existsSync(), isTrue);
    });
  });

  group('VrQuantizer', () {
    test('用量越大步长越粗, 预算耗尽后不再创建变体', () {
      final q = VrQuantizer(budget: 10);
      expect(q.level, 0);
      expect(q.angleStep, VrQuantizer.angleSteps[0]);
      expect(q.exhausted, isFalse);

      q.variants = 10;
      expect(q.exhausted, isTrue);
      q.countVariant();
      expect(q.variants, 11);
      expect(q.exhausted, isTrue);
    });

    test('降档阈值单调', () {
      final q = VrQuantizer();
      var lastLevel = -1;
      for (final threshold in VrQuantizer.levelThresholds) {
        q.variants = threshold;
        expect(q.level, greaterThan(lastLevel));
        lastLevel = q.level;
      }
      expect(q.level, VrQuantizer.angleSteps.length - 1);
    });

    test('角度与视场角步长档位数量一致', () {
      expect(
        VrQuantizer.angleSteps.length,
        VrQuantizer.fovSteps.length,
      );
      expect(
        VrQuantizer.angleSteps.length,
        VrQuantizer.levelThresholds.length,
      );
    });

    test('reset 归零', () {
      final q = VrQuantizer()..variants = 999;
      q.reset();
      expect(q.variants, 0);
      expect(q.level, 0);
      expect(q.exhausted, isFalse);
    });
  });
}
