import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/services/local_media/local_media_channel.dart';
import 'package:PiliPlus/services/local_media/log_ring.dart';
import 'package:PiliPlus/services/local_media/models.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:saver_gallery/saver_gallery.dart';

/// LAN discovery / browsing / downloads state, on top of libvlc's
/// MediaBrowser & Dumper (through the native bridge).
///
/// Credentials policy: only stored locally (bookmarks), UI and clipboard
/// always use the redacted form, never logged.
class LocalNetworkService extends GetxService {
  static LocalNetworkService get to => Get.find<LocalNetworkService>();

  final LocalMediaChannel _ch = LocalMediaChannel.instance;

  final RxList<NetItem> discovered = <NetItem>[].obs;
  final RxBool discovering = false.obs;
  final RxString engineError = ''.obs;
  final RxString browseUrl = ''.obs;
  final RxList<NetItem> browseItems = <NetItem>[].obs;
  final RxBool browsing = false.obs;
  final RxMap<int, double> downloadProgress = <int, double>{}.obs;
  final RxList<NetBookmark> bookmarks = Pref.localNetBookmarks
      .map((e) => NetBookmark(name: e.name, url: e.url))
      .toList()
      .obs;

  StreamSubscription<Map>? _sub;
  bool _loginDialogOpen = false;

  @override
  void onInit() {
    super.onInit();
    _sub = _ch.events.listen(_onEvent);
  }

  @override
  void onClose() {
    _sub?.cancel();
    super.onClose();
  }

  void _onEvent(Map event) {
    switch (event['type'] as String? ?? '') {
      case 'netDiscoveryItem':
        final item = NetItem.fromMap(event['item'] as Map? ?? const {});
        if (!discovered.any((e) => e.uri == item.uri)) discovered.add(item);
      case 'netItemRemoved':
        final uri = event['uri'] as String? ?? '';
        discovered.removeWhere((e) => e.uri == uri);
      case 'netBrowseItem':
        browseItems.add(NetItem.fromMap(event['item'] as Map? ?? const {}));
      case 'netBrowseDone':
        browsing.value = false;
      case 'netError':
        browsing.value = false;
        discovering.value = false;
        final msg = '${event['op']}: ${event['message']}';
        LocalLogRing.instance.w('LocalNetwork', msg);
      case 'downloadProgress':
        final id = (event['id'] as num?)?.toInt() ?? -1;
        downloadProgress[id] = (event['progress'] as num?)?.toDouble() ?? 0;
      case 'downloadDone':
        _onDownloadDone(event);
      case 'loginDialog':
        showLoginDialog(event);
      case 'vlcErrorDialog':
        // surfaced by the player page as well; log here for the network side
        LocalLogRing.instance.w(
          'LocalNetwork',
          'vlc dialog: ${event['title']} ${event['text']}',
        );
    }
  }

  void _onDownloadDone(Map event) {
    final id = (event['id'] as num?)?.toInt() ?? -1;
    final ok = event['ok'] == true;
    final pathStr = event['path'] as String?;
    final fileName = _pendingDownloads.remove(id) ?? 'download.mp4';
    downloadProgress.remove(id);
    if (ok && pathStr != null) {
      LocalLogRing.instance.i('LocalNetwork', 'download finished: $pathStr');
      // 转存到公共视频目录（相册/MediaStore 可见，媒体库随后可扫到）
      SaverGallery.saveFile(
        filePath: pathStr,
        fileName: fileName,
        albumPath: 'Movies/PiliPlus',
        skipIfExists: false,
      ).then((res) {
        if (res.isSuccess) {
          SmartDialog.showToast('下载完成：已保存到 Movies/PiliPlus');
        } else {
          SmartDialog.showToast('已下载，但转存相册失败：${res.errorMessage}');
        }
        File(pathStr).delete().catchError((_) => File(pathStr));
      }).catchError((Object e) {
        SmartDialog.showToast('转存失败：$e');
      });
    } else {
      final err = event['error'] as String? ?? 'unknown';
      LocalLogRing.instance.e('LocalNetwork', 'download failed: $err');
      SmartDialog.showToast('下载失败：$err');
    }
  }

  Future<void> startDiscovery() async {
    discovering.value = true;
    discovered.clear();
    engineError.value = '';
    try {
      await _ch.engineInit();
      await _ch.netDiscover();
    } catch (e) {
      discovering.value = false;
      engineError.value = '播放引擎初始化失败：$e';
      LocalLogRing.instance.e('LocalNetwork', 'discovery failed: $e');
    }
  }

  void stopDiscovery() {
    discovering.value = false;
    _ch.netStopDiscovery();
  }

  Future<void> browse(String url) async {
    browsing.value = true;
    browseUrl.value = url;
    browseItems.clear();
    try {
      await _ch.engineInit();
      await _ch.netBrowse(url);
    } catch (e) {
      browsing.value = false;
      LocalLogRing.instance.e('LocalNetwork', 'browse failed: $e');
    }
  }

  Future<int> download(String url, String destDir, String fileName) async {
    final id = await _ch.netDownload(url: url, destDir: destDir, fileName: fileName);
    if (id > 0) _pendingDownloads[id] = fileName;
    return id;
  }

  final Map<int, String> _pendingDownloads = {};

  void cancelDownload(int id) {
    _pendingDownloads.remove(id);
    _ch.netDownloadCancel(id);
  }

  // ---- bookmarks ----

  void addBookmark(NetBookmark b) {
    bookmarks.add(b);
    _persistBookmarks();
  }

  void removeBookmark(int index) {
    bookmarks.removeAt(index);
    _persistBookmarks();
  }

  void updateBookmark(int index, NetBookmark b) {
    bookmarks[index] = b;
    _persistBookmarks();
  }

  void _persistBookmarks() {
    Pref.localNetBookmarks = bookmarks
        .map((e) => NetBookmarkData(name: e.name, url: e.url))
        .toList();
  }

  // ---- credential dialog (SMB/WebDAV etc.) ----

  void showLoginDialog(Map event) {
    if (_loginDialogOpen) return;
    final context = Get.context;
    if (context == null) return;
    _loginDialogOpen = true;
    final id = (event['id'] as num?)?.toInt() ?? -1;
    final title = event['title'] as String? ?? '需要登录';
    final text = event['text'] as String? ?? '';
    final username = event['username'] as String? ?? '';
    final userController = TextEditingController(text: username);
    final passController = TextEditingController();

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (text.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                // 展示来源时脱敏
                child: Text(redactUrl(text)),
              ),
            TextField(
              controller: userController,
              decoration: const InputDecoration(labelText: '用户名'),
              autofillHints: const [AutofillHints.username],
            ),
            TextField(
              controller: passController,
              obscureText: true,
              decoration: const InputDecoration(labelText: '密码'),
              autofillHints: const [AutofillHints.password],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              _ch.dialogDismiss(id);
              Navigator.pop(dialogContext);
              _loginDialogOpen = false;
            },
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              _ch.dialogPostLogin(
                id: id,
                username: userController.text,
                password: passController.text,
              );
              Navigator.pop(dialogContext);
              _loginDialogOpen = false;
            },
            child: const Text('登录'),
          ),
        ],
      ),
    );
  }

  /// smb://user:pass@host -> smb://user:***@host（界面展示与复制一律脱敏）
  static String redactUrl(String url) => url.replaceFirstMapped(
        RegExp(r'://([^/@:]+):([^@/]+)@'),
        (m) => '://${m.group(1)}:***@',
      );
}
