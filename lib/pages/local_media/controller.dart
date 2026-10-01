import 'package:PiliPlus/models/local_media/vlc_media.dart';
import 'package:PiliPlus/pages/video/vlc/vlc_player_page.dart';
import 'package:PiliPlus/services/vlc/vlc_browser.dart';
import 'package:PiliPlus/services/vlc/vlc_library.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:PiliPlus/utils/permission_handler.dart';

/// 「本地」板块控制器: 数据全部来自 VLC 引擎(libmedialibrary 索引 +
/// libvlc MediaBrowser 网络发现/浏览), 见 docs/piliplayer.md §17。
class LocalMediaController extends GetxController {
  /// VLC 媒体库(libml): 扫描/索引/续播都在 native 侧持久化
  final VlcLibrary library = VlcLibrary.instance;

  /// 媒体库全部视频条目(索引完成前会随扫描进度增长)
  final RxList<VlcMediaItem> videos = <VlcMediaItem>[].obs;

  /// 最近播放(libml 历史, 含无 id 的网络流)
  final RxList<VlcMediaItem> history = <VlcMediaItem>[].obs;

  final RxBool libraryLoading = false.obs;

  /// 自动发现的 SMB 共享
  final RxList<VlcBrowseItem> shares = <VlcBrowseItem>[].obs;
  final RxBool discovering = false.obs;
  final RxnString networkError = RxnString();

  /// 手动保存的共享书签
  final RxList<VlcSavedShare> savedShares = <VlcSavedShare>[].obs;

  @override
  void onInit() {
    super.onInit();
    _loadSavedShares();
    bootstrap();
  }

  /// 权限 + 媒体库初始化 + 首次拉取(onInit 不能 await, 单独一个入口)
  Future<void> bootstrap() async {
    if (!await _ensurePermission()) {
      library.lastError.value = '未获得存储读取权限，无法扫描本机视频';
      return;
    }
    final ok = await library.init();
    if (!ok) {
      return;
    }
    await refreshVideos();
    // libml 的索引完成事件到达后再刷一次(边扫边出)
    ever(library.ready, (_) => refreshVideos());
    ever(library.busy, (busy) {
      if (!busy) {
        refreshVideos();
      }
    });
  }

  Future<bool> _ensurePermission() async {
    try {
      var status = await Permission.videos.status;
      if (!status.isGranted && !status.isLimited) {
        status = await Permission.videos.request();
      }
      if (status.isGranted || status.isLimited) {
        return true;
      }
      // 安卓 12 及以下没有 videos 权限, 退回 storage
      final legacy = await Permission.storage.request();
      return legacy.isGranted || legacy.isLimited;
    } catch (_) {
      return false;
    }
  }

  Future<void> refreshVideos() async {
    libraryLoading.value = true;
    try {
      videos.value = await library.videos();
      history.value = await library.history();
    } finally {
      libraryLoading.value = false;
    }
  }

  Future<void> rescan({bool full = false}) async {
    if (!await _ensurePermission()) {
      SmartDialog.showToast('未获得存储读取权限，无法扫描本机视频');
      return;
    }
    await library.rescan(full: full);
  }

  // ---------------------------------------------------------------- 排序/归组

  final Rx<VlcMediaSort> sort = Rx<VlcMediaSort>(Pref.vlcMediaSort);

  void setSort(VlcMediaSort value) {
    sort.value = value;
    GStorage.setting.put(SettingBoxKey.vlcMediaSort, value.index);
  }

  /// 按文件夹归组(参照 VLC 安卓版的文件夹视图)
  List<VlcFolderGroup> folderGroups() {
    final map = <String, List<VlcMediaItem>>{};
    for (final v in videos) {
      map.putIfAbsent(v.folderPath, () => []).add(v);
    }
    final groups = [
      for (final e in map.entries)
        VlcFolderGroup(
          path: e.key,
          name: _folderName(e.key),
          items: _sorted(e.value),
        ),
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return groups;
  }

  List<VlcMediaItem> _sorted(List<VlcMediaItem> items) {
    final list = List<VlcMediaItem>.of(items);
    switch (sort.value) {
      case VlcMediaSort.name:
        list.sort(
          (a, b) => a.displayName.toLowerCase().compareTo(
            b.displayName.toLowerCase(),
          ),
        );
      case VlcMediaSort.duration:
        list.sort((a, b) => b.lengthMs.compareTo(a.lengthMs));
      case VlcMediaSort.progress:
        list.sort((a, b) => b.timeMs.compareTo(a.timeMs));
      case VlcMediaSort.folder:
        break;
    }
    return list;
  }

  String _folderName(String path) {
    final i = path.lastIndexOf('/');
    final name = i >= 0 && i < path.length - 1 ? path.substring(i + 1) : path;
    return name.isEmpty ? '根目录' : name;
  }

  /// 某个文件夹下的视频(排序后)
  List<VlcMediaItem> videosInFolder(String folderPath) => _sorted([
    for (final v in videos)
      if (v.folderPath == folderPath) v,
  ]);

  // ---------------------------------------------------------------- 网络

  /// 发现局域网 SMB 共享(VLC「网络」页同款, libvlc MediaBrowser)
  Future<void> discoverShares() async {
    if (discovering.value) {
      return;
    }
    discovering.value = true;
    networkError.value = null;
    shares.clear();
    await VlcBrowser.instance.discoverShares(
      onItem: (item) {
        // 去重(发现服务可能重复上报)
        if (!shares.any((e) => e.uri == item.uri)) {
          shares.add(item);
        }
      },
      onEnd: () => discovering.value = false,
      onError: (msg) {
        networkError.value = msg;
        discovering.value = false;
      },
    );
  }

  @override
  void onClose() {
    VlcBrowser.instance.stop();
    super.onClose();
  }

  void _loadSavedShares() {
    final raw = GStorage.setting.get(SettingBoxKey.vlcSavedShares);
    if (raw is List) {
      savedShares.value = [
        for (final e in raw)
          if (e is Map) VlcSavedShare.fromMap(e),
      ];
    }
  }

  void addSavedShare(String name, String uri) {
    var fixed = uri.trim();
    if (fixed.isEmpty) {
      return;
    }
    if (!fixed.contains('://')) {
      fixed = 'smb://$fixed';
    }
    final title = name.trim().isEmpty ? fixed : name.trim();
    savedShares.add(VlcSavedShare(name: title, uri: fixed));
    _persistShares();
  }

  void removeSavedShare(VlcSavedShare share) {
    savedShares.removeWhere((e) => e.uri == share.uri && e.name == share.name);
    _persistShares();
  }

  void _persistShares() {
    GStorage.setting.put(
      SettingBoxKey.vlcSavedShares,
      savedShares.map((e) => e.toMap()).toList(),
    );
  }

  // ---------------------------------------------------------------- 播放入口

  /// 播放媒体库条目(播放列表 = 同文件夹的全部视频, 起点 = libml 续播位置)
  void playLibraryItem(VlcMediaItem item) {
    final siblings = videosInFolder(item.folderPath);
    final playlist = [
      for (final s in siblings)
        VlcPlaylistEntry(
          uri: s.uri,
          title: s.displayName,
          mlId: s.id,
          startMs: s.id == item.id && !s.finished ? s.timeMs : 0,
        ),
    ];
    final index = playlist.indexWhere((e) => e.uri == item.uri);
    Get.to(
      () => VlcPlayerPage(playlist: playlist, initialIndex: index < 0 ? 0 : index),
    )?.then((_) => refreshVideos());
  }

  /// 单独播放一个媒体库条目(可指定从头播); 续播仍会写回 libml
  void playLibraryItemSingle(VlcMediaItem item, {bool fromStart = false}) {
    Get.to(
      () => VlcPlayerPage(
        playlist: [
          VlcPlaylistEntry(
            uri: item.uri,
            title: item.displayName,
            mlId: item.id,
            startMs: fromStart || item.finished ? 0 : item.timeMs,
          ),
        ],
      ),
    )?.then((_) => refreshVideos());
  }

  /// 播放历史/网络流条目(无播放列表)
  void playUri(String uri, String title) {
    Get.to(
      () => VlcPlayerPage(
        playlist: [VlcPlaylistEntry(uri: uri, title: title)],
      ),
    )?.then((_) {
      refreshVideos();
    });
  }
}

/// 媒体库的文件夹归组
class VlcFolderGroup {
  const VlcFolderGroup({
    required this.path,
    required this.name,
    required this.items,
  });

  final String path;
  final String name;
  final List<VlcMediaItem> items;

  int get count => items.length;

  int get totalLengthMs =>
      items.fold(0, (sum, e) => sum + e.lengthMs);
}
