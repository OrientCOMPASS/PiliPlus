import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models/local_media/local_media_item.dart';
import 'package:PiliPlus/models/local_media/local_media_source.dart';
import 'package:PiliPlus/pages/local_media/browser.dart';
import 'package:PiliPlus/pages/local_media/library.dart';
import 'package:PiliPlus/pages/local_media/widgets/source_editor.dart';
import 'package:PiliPlus/services/local_media_service.dart';
import 'package:PiliPlus/services/smb/smb_discovery.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// 「本地」板块控制器: 本机媒体库(按文件夹归组) + 局域网发现 + 已保存的来源。
class LocalMediaController extends GetxController {
  final LocalMediaLibrary library = LocalMediaLibrary();

  /// 本机存储卷(主存储 + SD 卡/U 盘)
  final RxList<LocalMediaSource> deviceSources = <LocalMediaSource>[].obs;

  /// 用户添加的网络共享(SMB / WebDAV / HTTP / FTP)
  final RxList<LocalMediaSource> savedSources = <LocalMediaSource>[].obs;

  /// 自动发现的 SMB 主机
  final RxList<SmbHost> discovered = <SmbHost>[].obs;

  final RxBool scanningNetwork = false.obs;
  final RxInt scanDone = 0.obs;
  final RxInt scanTotal = 0.obs;
  final RxnString networkError = RxnString();

  @override
  void onInit() {
    super.onInit();
    library.loadCache();
    savedSources.value = LocalMediaService.loadSources();
    refreshDevices();
    // 第一次进入且没有缓存时自动扫描一次
    if (library.folders.isEmpty) {
      library.scan();
    }
  }

  @override
  void onClose() {
    library.cancelScan();
    super.onClose();
  }

  Future<void> refreshDevices() async {
    deviceSources.value = await LocalMediaService.deviceSources();
  }

  Future<void> rescanLibrary() async {
    if (!await LocalMediaService.ensureDevicePermission()) {
      SmartDialog.showToast('未获得存储读取权限，无法扫描本机视频');
      return;
    }
    await library.scan();
    if (library.lastError.value case final err?) {
      SmartDialog.showToast(err);
    }
  }

  /// 扫描局域网里开着 SMB(445) 端口的主机
  Future<void> discoverNetwork() async {
    if (scanningNetwork.value) {
      return;
    }
    scanningNetwork.value = true;
    networkError.value = null;
    scanDone.value = 0;
    scanTotal.value = 0;
    try {
      final hosts = await SmbDiscovery.scan(
        onProgress: (done, total) {
          scanDone.value = done;
          scanTotal.value = total;
        },
      );
      discovered.value = hosts;
      if (hosts.isEmpty) {
        networkError.value =
            '没有发现开启 SMB(445) 的主机。请确认与 NAS/电脑在同一局域网，'
            '或手动添加共享地址。';
      }
    } catch (err) {
      networkError.value = err.toString();
    } finally {
      scanningNetwork.value = false;
    }
  }

  // ==================== 打开 ====================

  /// 媒体库里的文件夹 -> 浏览页
  Future<void> openFolder(LocalMediaFolder folder) async {
    final source = LocalMediaSource(
      type: LocalMediaSourceType.device,
      name: folder.name,
      url: folder.path,
    );
    final items = await library.itemsOf(folder);
    Get.to(
      () => LocalMediaBrowserPage(
        source: source,
        path: folder.path,
        title: folder.name,
        initialItems: items,
      ),
    );
  }

  /// 本机存储卷 -> 浏览页
  Future<void> openDevice(LocalMediaSource source) async {
    if (!await LocalMediaService.ensureDevicePermission()) {
      SmartDialog.showToast('未获得存储读取权限，无法浏览本机文件');
      return;
    }
    _browse(source, source.rootPath, source.name);
  }

  /// 已保存的网络来源
  Future<void> openSource(LocalMediaSource source) async {
    if (!source.canBrowse) {
      // 直链来源: 没有目录可浏览, 直接播放
      final item = LocalMediaItem(
        name: source.name,
        uri: source.playbackBase,
        source: source,
      );
      Get.to(
        () => LocalMediaBrowserPage(
          source: source,
          path: '',
          title: source.name,
          initialItems: [item],
        ),
      );
      return;
    }
    _browse(source, source.rootPath, source.name);
  }

  void _browse(LocalMediaSource source, String path, String title) {
    Get.to(
      () => LocalMediaBrowserPage(source: source, path: path, title: title),
    );
  }

  /// 发现的主机 -> 让用户填共享名与凭据 -> 保存并打开
  Future<void> openDiscoveredHost(
    BuildContext context,
    SmbHost host,
  ) async {
    final preset = LocalMediaSource(
      type: LocalMediaSourceType.smb,
      name: host.displayName,
      url: 'smb://${host.address}/',
    );
    final source = await showSourceEditor(context, initial: preset);
    if (source == null) {
      return;
    }
    SmartDialog.showLoading(msg: '连接中');
    final res = await LocalMediaService.testConnection(source);
    SmartDialog.dismiss();
    switch (res) {
      case Success():
        await addSource(source);
        openSource(source);
      case Error(:final errMsg):
        SmartDialog.showToast(errMsg ?? '连接失败');
      case _:
        break;
    }
  }

  Future<void> addSourceFromDialog(BuildContext context) async {
    final source = await showSourceEditor(context);
    if (source != null) {
      await addSource(source);
    }
  }

  // ==================== 来源管理 ====================

  Future<void> addSource(LocalMediaSource source) async {
    if (!savedSources.contains(source)) {
      savedSources.add(source);
    }
    await _persist();
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
    await _persist();
  }

  Future<void> removeSource(LocalMediaSource source) async {
    savedSources.remove(source);
    await _persist();
  }

  Future<void> _persist() => LocalMediaService.saveSources(savedSources);

  Future<void> editSource(BuildContext context, LocalMediaSource source) async {
    final updated = await showSourceEditor(context, initial: source);
    if (updated != null) {
      await replaceSource(source, updated);
    }
  }

}
