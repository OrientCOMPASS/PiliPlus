import 'dart:convert' show utf8;

import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models/common/video/source_type.dart';
import 'package:PiliPlus/models/local_media/local_media_item.dart';
import 'package:PiliPlus/models/local_media/local_media_sort.dart';
import 'package:PiliPlus/models/local_media/local_media_source.dart';
import 'package:PiliPlus/services/local_media_service.dart';
import 'package:PiliPlus/utils/local_media_progress.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:archive/archive.dart' show getCrc32;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';

/// 浏览路径栈中的一层
class LocalMediaPath {
  const LocalMediaPath({
    required this.source,
    required this.path,
    required this.title,
  });

  final LocalMediaSource source;
  final String path;
  final String title;
}

class LocalMediaController extends GetxController {
  /// 用户添加的网络共享
  final RxList<LocalMediaSource> savedSources = <LocalMediaSource>[].obs;

  /// 本机存储卷(主存储 + SD 卡/U 盘)
  final RxList<LocalMediaSource> deviceSources = <LocalMediaSource>[].obs;

  /// 目录栈, 为空表示停留在「来源列表」
  final RxList<LocalMediaPath> stack = <LocalMediaPath>[].obs;

  final Rx<LoadingState<List<LocalMediaItem>>> state = Rx(
    LoadingState.loading(),
  );

  final RxBool loadingDevices = false.obs;

  LocalMediaSort sort = Pref.localMediaSort;
  bool showHidden = Pref.localMediaShowHidden;

  List<LocalMediaItem> get items => state.value.dataOrNull ?? const [];

  bool get isRoot => stack.isEmpty;

  LocalMediaPath? get current => stack.isEmpty ? null : stack.last;

  @override
  void onInit() {
    super.onInit();
    savedSources.value = LocalMediaService.loadSources();
    refreshDevices();
  }

  // ==================== 浏览 ====================

  Future<void> refreshDevices() async {
    loadingDevices.value = true;
    try {
      deviceSources.value = await LocalMediaService.deviceSources();
    } finally {
      loadingDevices.value = false;
    }
  }

  Future<void> refresh() async {
    final cur = current;
    if (cur == null) {
      state.value = Success(const <LocalMediaItem>[]);
      return;
    }
    state.value = LoadingState.loading();
    state.value = await LocalMediaService.list(
      source: cur.source,
      path: cur.path,
      sort: sort,
      showHidden: showHidden,
    );
  }

  Future<void> openSource(LocalMediaSource source) async {
    if (!source.canBrowse) {
      // HTTP / FTP 直链来源: 没有目录可浏览, 直接播放
      // playbackBase 已经把账号密码拼进 URL, 交给 mpv 处理认证
      play(
        LocalMediaItem(
          name: source.name,
          uri: source.playbackBase,
          source: source,
        ),
      );
      return;
    }
    if (source.type == LocalMediaSourceType.device) {
      if (!await LocalMediaService.ensureDevicePermission()) {
        SmartDialog.showToast('未获得存储读取权限，无法浏览本机文件');
        return;
      }
    }
    stack.add(
      LocalMediaPath(source: source, path: source.rootPath, title: source.name),
    );
    await refresh();
  }

  Future<void> openItem(LocalMediaItem item) async {
    if (!item.isDirectory) {
      play(item);
      return;
    }
    final cur = current;
    if (cur == null) {
      return;
    }
    final childPath = cur.source.type == LocalMediaSourceType.device
        ? item.uri
        : item.remotePath ?? item.uri;
    stack.add(
      LocalMediaPath(source: cur.source, path: childPath, title: item.name),
    );
    await refresh();
  }

  /// 返回上一层; 返回 false 表示已经在来源列表, 交给路由 pop
  bool back() {
    if (stack.isEmpty) {
      return false;
    }
    stack.removeLast();
    refresh();
    return true;
  }

  /// 面包屑跳转, [index] 为 -1 表示回到来源列表
  Future<void> goToLevel(int index) async {
    if (index >= stack.length - 1) {
      return;
    }
    if (index < -1) {
      return;
    }
    stack.removeRange(index + 1, stack.length);
    await refresh();
  }

  Future<void> setSort(LocalMediaSort value) async {
    sort = value;
    await GStorage.setting.put(SettingBoxKey.localMediaSort, value.index);
    final cur = state.value.dataOrNull;
    if (cur != null) {
      state.value = Success(LocalMediaService.sortItems(cur, value));
    }
  }

  Future<void> toggleHidden() async {
    showHidden = !showHidden;
    await GStorage.setting.put(SettingBoxKey.localMediaShowHidden, showHidden);
    await refresh();
  }

  // ==================== 播放 ====================

  /// 本地媒体没有 cid, 用 uri 的 crc32 合成一个稳定 int
  /// (只用于 heroTag / GetX tag, 不会发给任何接口)
  static int cidOf(String uri) => getCrc32(utf8.encode(uri));

  /// 播放一个条目, 同目录的其他视频自动作为播放列表(类似 VLC 的文件夹播放)
  void play(LocalMediaItem item, {List<LocalMediaItem>? playlist}) {
    final siblings = playlist ?? items.where((e) => e.isVideo).toList();
    final index = siblings.indexWhere((e) => e.uri == item.uri);
    final list = index >= 0 ? siblings : <LocalMediaItem>[item];
    PageUtils.toVideoPage(
      aid: 0,
      bvid: '',
      cid: cidOf(item.uri),
      title: item.name,
      extraArguments: {
        'sourceType': SourceType.localMedia,
        'localMedia': item,
        'localPlaylist': list,
        'localIndex': index >= 0 ? index : 0,
      },
    );
  }

  Duration? progressOf(LocalMediaItem item) => LocalMediaProgress.get(item.uri);

  // ==================== 来源管理 ====================

  Future<void> addSource(LocalMediaSource source) async {
    savedSources.add(source);
    await LocalMediaService.saveSources(savedSources);
  }

  Future<void> replaceSource(
    LocalMediaSource old,
    LocalMediaSource updated,
  ) async {
    final index = savedSources.indexOf(old);
    if (index < 0) {
      return;
    }
    savedSources[index] = updated;
    await LocalMediaService.saveSources(savedSources);
  }

  Future<void> removeSource(LocalMediaSource source) async {
    savedSources.remove(source);
    await LocalMediaService.saveSources(savedSources);
  }
}
