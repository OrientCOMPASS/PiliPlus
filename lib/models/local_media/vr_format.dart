import 'package:PiliPlus/models/common/enum_with_label.dart';

/// VR / 全景视频的片源格式(播放页手动指定或按文件名自动识别)。
///
/// 渲染由 VR 补丁版 libvlc 完成(tool/libvlc-vr, docs §18):枚举经
/// [bridgeMode] 映射为 `VlcPlayerBridge` 的 vrMode 参数, 桥再翻译成
/// 定制 libvlc 的 media 选项 `:vr-projection` / `:vr-layout` /
/// `:vr-coverage` / `:vr-eye`。官方 libvlc 会静默忽略这些选项
/// (引擎是否带补丁由 `LibVLC.changeset()` 的 `piliplus-vr` 标记探测)。
enum VrFormat with EnumWithLabel {
  /// 跟随片源元数据(libvlc 原生行为): 有等距柱状/立体元数据的片源
  /// 自动进入环视; 无元数据的按平面播放。
  auto('自动(元数据)'),
  off('强制平面(2D)'),
  e360('360° 单目'),
  sbs360('360° 左右(SBS)'),
  tb360('360° 上下(TB)'),
  e180('180° 单目'),
  sbs180('180° 左右(SBS)'),
  tb180('180° 上下(TB)'),
  ;

  @override
  final String label;
  const VrFormat(this.label);

  /// Kotlin `VlcPlayerBridge` 的 vrMode 取值(与枚举序一致: 0..7)
  int get bridgeMode => index;

  /// 强制进入沉浸式(球面)渲染 —— auto 不算(是否沉浸由元数据决定)
  bool get forcesImmersive =>
      this == e360 ||
      this == sbs360 ||
      this == tb360 ||
      this == e180 ||
      this == sbs180 ||
      this == tb180;

  /// 双目(3D)片源: 渲染时只取其中一只眼睛(眼位可切换)
  bool get isStereo =>
      this == sbs360 || this == tb360 || this == sbs180 || this == tb180;

  /// 水平覆盖角(度): 180° 片源手动偏航要在边界收敛, 避免转出画面见黑
  double get coverageH => switch (this) {
    e180 || sbs180 || tb180 => 180.0,
    _ => 360.0,
  };

  /// 根据文件名猜测片源格式; 没有任何明确线索时返回 null(交给 [auto])。
  ///
  /// 移植自 mpv VR 时代验证过的启发式(git 历史 vr_projection.dart):
  /// 只认明确关键词, 且对 `360`/`180`/`vr`/`tb` 这类容易误伤的短词做
  /// 词边界匹配——否则清晰度 `360p`、`1080p` 会被误判成全景片源。
  /// 宽高比不作为判据: 2:1 也可能是普通宽银幕视频。
  static VrFormat? detectFromName(String name) {
    final n = name.toLowerCase();
    // 字母边界匹配, 允许数字紧邻(如 `360vr`)
    bool word(String key) => RegExp('(^|[^a-z])$key([^a-z]|\$)').hasMatch(n);
    // 数字关键词: 排除 `360p` / `1080p` 这类清晰度写法
    bool numberWord(String key) =>
        RegExp('(^|[^0-9])$key([^0-9p]|\$)').hasMatch(n);
    bool has(List<String> keys) => keys.any(n.contains);

    final is180 = numberWord('180');
    final is360 = numberWord('360');
    final isVr = word('vr') || has(['全景']);

    final sbs =
        word('sbs') ||
        has(['左右格式', '左右3d', '3d左右', 'lr3d', '3dlr', '左右']);
    final tb =
        word('tb') ||
        word('ou') ||
        has(['over-under', 'over_under', '上下格式', '上下3d', '3d上下', '上下']);

    final pano =
        isVr ||
        is360 ||
        is180 ||
        word('pano') ||
        has(['equirect', 'equi-angular', 'panoram', 'spherical']);
    // 只有 `3d` 字样无法判断片源布局, 不乱猜
    if (!pano && !sbs && !tb) {
      return null;
    }

    // tb 与 sbs 同时出现时以 sbs 为准(更常见的命名)
    if (tb && !sbs) {
      return is180 && !is360 ? VrFormat.tb180 : VrFormat.tb360;
    }
    if (sbs) {
      return is180 && !is360 ? VrFormat.sbs180 : VrFormat.sbs360;
    }
    return is180 && !is360 ? VrFormat.e180 : VrFormat.e360;
  }
}
