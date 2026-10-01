import 'package:PiliPlus/models/common/nav_bar_config.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';

/// One-shot migrations introduced by the local media module.
///
/// Each migration is guarded by a flag and never overwrites later user
/// customizations again.
abstract final class LocalMigrations {
  static const List<double> _oldDefaultSpeeds = [
    0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 3.0,
  ];
  static const List<double> _newDefaultSpeeds = [
    0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 4.0, 8.0,
  ];

  static Future<void> run() async {
    _migrateSpeedList();
    _migrateNavBar();
  }

  /// 倍速预设一次性迁移（不覆盖用户自定义档位）：
  /// 移除历史上去掉的 0.75/1.25/1.75，补齐 2.5/4/8，用户额外添加的保留。
  static void _migrateSpeedList() {
    if (GStorage.video.get(VideoBoxKey.speedsListMigratedV2, defaultValue: false) == true) {
      return;
    }
    final raw = GStorage.video.get(VideoBoxKey.speedsList);
    if (raw is List) {
      final old = raw.whereType<num>().map((e) => e.toDouble()).toSet();
      old.remove(0.75);
      old.remove(1.25);
      old.remove(1.75);
      old.addAll([2.5, 4.0, 8.0]);
      final merged = old.toList()..sort();
      GStorage.video.put(VideoBoxKey.speedsList, merged);
    }
    GStorage.video.put(VideoBoxKey.speedsListMigratedV2, true);
  }

  /// 老用户导航配置不错位：已保存的 navBarSort 原样保留，仅在末尾追加
  /// 一次「本地」；用户随后可在「设置 → Navbar 编辑」中自由增删/排序。
  static void _migrateNavBar() {
    if (GStorage.setting.get(LocalSettingKey.navBarLocalMigrated, defaultValue: false) == true) {
      return;
    }
    final raw = GStorage.setting.get(SettingBoxKey.navBarSort);
    if (raw is List && raw.isNotEmpty) {
      final list = raw.whereType<num>().map((e) => e.toInt()).toList();
      final localOrdinal = NavigationBarType.local.index;
      if (!list.contains(localOrdinal)) {
        list.add(localOrdinal);
        GStorage.setting.put(SettingBoxKey.navBarSort, list);
      }
    }
    GStorage.setting.put(LocalSettingKey.navBarLocalMigrated, true);
  }

  /// 默认倍速档位（未自定义时）。
  static List<double> get defaultSpeeds => List<double>.from(_newDefaultSpeeds);

  static bool isOldDefault(List<double> list) {
    if (list.length != _oldDefaultSpeeds.length) return false;
    for (var i = 0; i < list.length; i++) {
      if (list[i] != _oldDefaultSpeeds[i]) return false;
    }
    return true;
  }
}
