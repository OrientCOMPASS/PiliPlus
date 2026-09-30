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
/// ## 参数只能烘焙进源码 —— 以及它的代价(第四轮真机排查结论)
///
/// mpv 0.41 的 `vo=gpu` 用户着色器**不支持 `//!PARAM`**
/// (`video/out/gpu/user_shaders.c` 里只解析 HOOK/BIND/SAVE/DESC/OFFSET/WIDTH/
/// HEIGHT/WHEN/COMPONENTS/TEXTURE/SIZE/FORMAT/FILTER/BORDER, 没有 PARAM;
/// `glsl-shader-opts` 选项虽然在 `gpu/video.c:548` 声明了, 但 `vo=gpu` 根本
/// 不读它 —— 只有 `vo=gpu-next` 会在 `update_hook_opts()` 里把键值对灌进
/// hook 的 param)。所以 yaw/pitch/fov 只能以 `#define` 形式写进源码。
///
/// 这带来两个必须绕开的 mpv 行为(都在 v0.41.0 源码里核对过):
///
/// 1. **用户着色器文件的内容按"路径"永久缓存**
///    (`gpu/video.c: load_cached_file()`: `p->files[]` 只增不减, 命中
///    `strcmp(path)` 就直接返回**第一次读到的内容**, 直到 `gl_video` 销毁)。
///    => 反复改写同一个文件再 `change-list glsl-shaders set <同一路径>`
///    是**永远看不到新内容的**; 两个槽位轮流写也不行(第三轮真机就是这么
///    翻车的: 读数在变、画面停在 VR 初始化那一刻, 因为 a/b 两个文件的内容
///    在各自第一次被读走之后就冻结了)。
///    => 唯一正确的做法: **一个文件只写一次, 内容变了就换新文件名**
///    (本类的 [writeUnique]), 并在 Dart 侧记住"源码 -> 路径"的映射,
///    同一份源码复用同一路径(mpv 那边是缓存命中, 不会重新编译)。
///
/// 2. **改 `glsl-shaders` 会触发整条渲染管线重建**
///    (`gl_video_render_frame()` 开头调 `gl_video_update_options()` ->
///    `m_config_cache_update()` 发现选项变了 -> `reinit_from_options()` ->
///    `uninit_rendering()` + `gl_video_setup_hooks()` + 重新解析/编译着色器)。
///    源码没变时能命中 `gl_shader_cache` 的程序缓存(不重新编译), 源码变了
///    就要**真的编译一次 GLSL**, 并且新程序会永久留在 `sc->entries[]` 里
///    (`sc_flush_cache()` 只在 `gl_sc_destroy()` 时调用), 开了
///    `--gpu-shader-cache` 还会往磁盘写一个缓存文件。
///    => 因此每帧/每 45ms 重写一次源码在工程上是不成立的: 既卡顿, 又让
///    mpv 进程内的程序缓存和磁盘缓存无限膨胀。
///    => 对策见 [VrQuantizer](量化 + 自适应降精度)与
///    `PlPlayerController.applyVrView`(节流 + 串行 + 预算)。
///
/// 升级路径: 等安卓端 mpv 换成支持 `vo=gpu` PARAM 的版本, 或确认
/// `vo=gpu-next` 在 media_kit 的安卓 surface 流程下可用, 只需把 [source]
/// 里的 `#define` 换成 `//!PARAM` 块、把下发命令换成
/// `setProperty('glsl-shader-opts', ...)`, 其余代码(投影数学、控制层)不动,
/// 那时才能做到"改参数不重编译"的逐帧头追。
abstract final class VrShader {
  /// 着色器文件名前缀。`_verifyVrShader` 回读 `glsl-shaders` 时用它确认
  /// 下发的是我们的着色器。
  static const String filePrefix = 'piliplus_vr_';

  /// `//!DESC` 里的标识。下发后回读 `vo-passes` 用它确认着色器真的进了渲染管线。
  static const String passDesc = 'PiliPlus-VR';

  static String get dirPath => path.join(appSupportDirPath, 'vr_shader');

  /// 每个序号一个**只写一次**的文件。用 36 进制只是为了文件名短一点。
  static String fileNameFor(int seq) =>
      '$filePrefix${seq.toRadixString(36)}.glsl';

  static String filePathFor(int seq) => path.join(dirPath, fileNameFor(seq));

  /// 写入一份**新的、此后不再改动**的着色器源码, 返回路径。
  ///
  /// 见类注释: mpv 按路径永久缓存文件内容, 所以同一个路径绝不能写第二次,
  /// 否则 mpv 读到的还是旧内容。
  static String writeUnique(int seq, String content) {
    final file = File(filePathFor(seq));
    if (!file.parent.existsSync()) {
      file.parent.createSync(recursive: true);
    }
    file.writeAsStringSync(content, flush: false);
    return file.path;
  }

  /// 清掉上一个播放器实例留下的着色器文件。
  ///
  /// 只在**播放器还没创建**时调用(`PlPlayerController._initPlayer` 之前):
  /// 播放器活着的时候删文件是危险的 —— media_kit 在 surface 尺寸变化时会
  /// 重设 `vo=gpu`, 那会重建 `gl_video` 并从磁盘**重新读取**当前
  /// `glsl-shaders` 指向的文件, 文件没了着色器就静默失效。
  static void purge() {
    try {
      final dir = Directory(dirPath);
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
    } catch (_) {
      // 清理失败不影响功能, 顶多多占几十 KB
    }
  }

  /// 生成着色器源码。**相同参数必须生成完全相同的源码**: 既为了命中
  /// Dart 侧的"源码 -> 路径"映射(避免重复写文件), 也为了命中 mpv 的
  /// GLSL 程序缓存(避免重复编译)。
  static String source({
    required VrProjection projection,
    required VrEye eye,
    required VrViewState view,
    required double angleStep,
    required double fovStep,
  }) {
    final state = view.clamped(projection);
    final yaw = VrViewState.quantize(state.yaw, angleStep);
    final pitch = VrViewState.quantize(state.pitch, angleStep);
    final fov = VrViewState.quantize(state.fov, fovStep);

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
}

/// 着色器"变体预算"与量化步长的自适应降档。
///
/// 每一个不同的量化视角 = 一份不同的着色器源码 = mpv 那边一次真实的 GLSL
/// 编译 + 一条永久驻留的程序缓存(见 [VrShader] 类注释第 2 点)。所以变体
/// 数量必须有上限, 否则长时间开着陀螺仪会把播放器进程的内存和
/// `--gpu-shader-cache` 目录一路吃上去。
///
/// 做法不是"到上限就罢工", 而是**随用量把量化步长放大**: 步长越大, 同样的
/// 头部运动落进的格子越少, 新增变体越慢, 而且回到看过的视角是缓存命中
/// (不编译、不占预算)。于是功能一直在, 只是精度随用量平滑下降。
class VrQuantizer {
  VrQuantizer({this.budget = defaultBudget});

  /// 一个播放器实例内允许创建的着色器变体上限
  static const int defaultBudget = 1500;

  /// 各档位启用的变体数阈值(达到即降一档精度)
  static const List<int> levelThresholds = [0, 200, 600, 1100];

  /// 各档位的角度量化步长(度)
  static const List<double> angleSteps = [0.5, 1.0, 2.0, 4.0];

  /// 各档位的视场角量化步长(度)
  static const List<double> fovSteps = [1.0, 2.0, 4.0, 8.0];

  final int budget;

  /// 已创建的变体数(= 已写过的着色器文件数)
  int variants = 0;

  int get level {
    var lv = 0;
    for (var i = 0; i < levelThresholds.length; i++) {
      if (variants >= levelThresholds[i]) {
        lv = i;
      }
    }
    return lv;
  }

  double get angleStep => angleSteps[level];

  double get fovStep => fovSteps[level];

  /// 预算用尽: 不再创建新变体(已见过的视角仍可复用)
  bool get exhausted => variants >= budget;

  void countVariant() => variants++;

  /// 播放器重建后 mpv 侧的缓存也没了, 这里一并归零
  void reset() => variants = 0;
}
