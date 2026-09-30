import 'dart:io';

import 'package:PiliPlus/plugin/pl_player/models/vr_projection.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:path/path.dart' as path;

/// VR / 全景重投影着色器(mpv 用户着色器, GLSL hook)。
///
/// 为什么用着色器而不是别的方案(性能对比见 docs/piliplayer.md):
///   * 安卓端打包的 FFmpeg 关闭了绝大部分滤镜(`--disable-filters`, 只放开了
///     overlay/equalizer/aresample/dynaudnorm/loudnorm/alimiter), **没有 v360**,
///     也没有 `buffer`/`buffersink`, 因此 `--vf=lavfi=[v360=...]` 这条路走不通;
///   * 着色器跑在 `vo=gpu` 的渲染管线里, 直接在硬件解码出来的纹理上采样,
///     **零拷贝、单次 fullscreen pass**, 并且 pass 输出尺寸被限制为
///     `OUTPUT.w x OUTPUT.h`(屏幕分辨率), 与片源分辨率(常见 4K/8K 全景)无关;
///   * 仓库内的 Anime4K 超分着色器用的是同一套机制(`HOOK MAIN` +
///     `WIDTH/HEIGHT OUTPUT.w/h`), 在本项目的 mpv 构建上已被验证可用。
///
/// mpv 0.41 的 `vo=gpu` 还不支持用户着色器 PARAM(mpv master 才把 PARAM 补进
/// `vo=gpu`, 且安卓端 media_kit 固定使用 `vo=gpu` + opengl-es), 所以视角参数
/// 以 `#define` 的形式烘焙进源码, 视角变化时节流重载(见
/// `PlPlayerController.applyVrView`)。
abstract final class VrShader {
  /// 着色器在 **两个槽位文件之间交替写入**(`piliplus_vr_a.glsl` /
  /// `piliplus_vr_b.glsl`)。
  ///
  /// 这是修一个真机 bug: 之前永远写同一个文件再
  /// `change-list glsl-shaders set <同一路径>`, 选项值没变化, mpv 判定
  /// opts 未变更、不会重读文件 —— 于是"方向按钮读数在变、画面却不动"、
  /// 播放中切换展开格式也不生效。交替文件名让每次下发的选项值都不同,
  /// 必然触发渲染管线重建; 两个文件循环覆盖, 也不会无限增长。
  static const String filePrefix = 'piliplus_vr_';

  /// `//!DESC` 里的标识。下发后回读 `vo-passes` 用它确认着色器真的进了渲染管线
  /// (见 `PlPlayerController._verifyVrShader`)。
  static const String passDesc = 'PiliPlus-VR';

  static String get dirPath => path.join(appSupportDirPath, 'vr_shader');

  static String fileNameFor(int slot) =>
      slot.isEven ? '${filePrefix}a.glsl' : '${filePrefix}b.glsl';

  static String filePathFor(int slot) => path.join(dirPath, fileNameFor(slot));

  /// 生成着色器源码。相同参数必须生成完全相同的源码, 以便命中 mpv 的程序缓存。
  static String source({
    required VrProjection projection,
    required VrEye eye,
    required VrViewState view,
  }) {
    final state = view.clamped(projection);
    // 量化: 既减少着色器重载次数, 也让重复视角命中 mpv 的 shader cache
    final yaw = VrViewState.quantize(state.yaw, VrViewState.angleStep);
    final pitch = VrViewState.quantize(state.pitch, VrViewState.angleStep);
    final fov = VrViewState.quantize(state.fov, VrViewState.fovStep);

    // 立体片源只取一只眼睛: 左右格式在 u 方向对半分, 上下格式在 v 方向对半分
    final rect = eyeRect(projection, eye);

    return '''
//!DESC $passDesc ${projection.label} yaw=$yaw pitch=$pitch fov=$fov
//!HOOK MAIN
//!BIND HOOKED
//!WIDTH OUTPUT.w
//!HEIGHT OUTPUT.h

#define VR_YAW ${_f(yaw)}
#define VR_PITCH ${_f(pitch)}
#define VR_FOV ${_f(fov)}
#define VR_COVERAGE_H ${_f(projection.coverageH)}
#define VR_U0 ${_f(rect.u0)}
#define VR_U1 ${_f(rect.u1)}
#define VR_V0 ${_f(rect.v0)}
#define VR_V1 ${_f(rect.v1)}
#define VR_PI 3.14159265358979

vec3 vrRotateX(vec3 v, float a) {
  float c = cos(a);
  float s = sin(a);
  return vec3(v.x, c * v.y - s * v.z, s * v.y + c * v.z);
}

vec3 vrRotateY(vec3 v, float a) {
  float c = cos(a);
  float s = sin(a);
  return vec3(c * v.x + s * v.z, v.y, -s * v.x + c * v.z);
}

vec4 hook() {
  // HOOKED_pos: 当前像素在本 pass 输出纹理中的归一化坐标, 范围 [0,1]
  vec2 uv = HOOKED_pos;
  // 本 pass 的输出会被缩放贴到视频区域(dst rect), 因此按视频区域的宽高比投影,
  // 缩放后画面几何关系才是正确的(全屏/半屏、fit 模式变化都会自动跟随)
  // 首帧或尺寸未知时 target_size 可能为 0, 这里兜底避免画面被拉成一条
  float aspect = clamp(
      max(target_size.x, 1.0) / max(target_size.y, 1.0), 0.1, 20.0);
  float tanH = tan(radians(VR_FOV) * 0.5);
  float tanV = tanH / max(aspect, 0.01);
  vec2 sc = (uv - 0.5) * 2.0;
  vec3 dir = normalize(vec3(sc.x * tanH, -sc.y * tanV, 1.0));
  // 先俯仰后偏航, 俯仰不会引入滚转
  dir = vrRotateX(dir, radians(-VR_PITCH));
  dir = vrRotateY(dir, radians(VR_YAW));
  float lon = atan(dir.x, dir.z);
  float lat = asin(clamp(dir.y, -1.0, 1.0));
  float u = lon / radians(VR_COVERAGE_H) + 0.5;
  float v = 0.5 - lat / VR_PI;
  if (VR_COVERAGE_H >= 360.0) {
    // 360 片源: 水平方向无缝回绕
    u = fract(u);
  } else {
    u = clamp(u, 0.0, 1.0);
  }
  v = clamp(v, 0.0, 1.0);
  // 双目片源取单眼区域
  u = mix(VR_U0, VR_U1, u);
  v = mix(VR_V0, VR_V1, v);
  return HOOKED_tex(vec2(u, v));
}
''';
  }

  /// GLSL 的 float 字面量必须带小数点
  static String _f(double value) => value.toStringAsFixed(3);

  /// 单眼画面在片源纹理中的归一化区域
  static ({double u0, double u1, double v0, double v1}) eyeRect(
    VrProjection projection,
    VrEye eye,
  ) {
    if (!projection.isStereo) {
      return (u0: 0.0, u1: 1.0, v0: 0.0, v1: 1.0);
    }
    final isLeft = eye == VrEye.left;
    if (projection.isSideBySide) {
      return (
        u0: isLeft ? 0.0 : 0.5,
        u1: isLeft ? 0.5 : 1.0,
        v0: 0.0,
        v1: 1.0,
      );
    }
    return (
      u0: 0.0,
      u1: 1.0,
      v0: isLeft ? 0.0 : 0.5,
      v1: isLeft ? 0.5 : 1.0,
    );
  }

  /// 把源码写到指定槽位并返回路径。
  ///
  /// 用同步写入: 文件很小(2KB 左右), 但可以保证写入顺序与视角更新顺序一致,
  /// 避免异步写入乱序导致视角抖动。槽位交替保证 mpv 每次都看到"新"的文件名。
  static String write(int slot, String content) {
    final file = File(filePathFor(slot));
    if (!file.parent.existsSync()) {
      file.parent.createSync(recursive: true);
    }
    file.writeAsStringSync(content);
    return file.path;
  }

  static void remove() {
    try {
      final dir = Directory(dirPath);
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
    } catch (_) {
      // 忽略清理失败
    }
  }
}
