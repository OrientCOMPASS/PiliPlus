import 'dart:async';

import 'package:PiliPlus/models/local_media/vlc_media.dart';
import 'package:PiliPlus/pages/video/vlc/vlc_player_page.dart';
import 'package:PiliPlus/services/vlc/vlc_browser.dart';
import 'package:PiliPlus/utils/duration_utils.dart';
import 'package:PiliPlus/utils/path_utils.dart' show downloadPath;
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/services.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as path;

/// VLC 网络目录浏览页(smb/ftp/nfs/upnp/文件目录均可)。
///
/// 浏览由 libvlc MediaBrowser 原生完成(逐层进入、结果边到边出);
/// 播放把 URI 直接交给 libvlc —— 不再有 Dart SMB2 客户端与回环代理,
/// seek 即 libsmb2 定位读, 与 VLC 安卓端行为一致。
class VlcBrowsePage extends StatefulWidget {
  const VlcBrowsePage({super.key, required this.rootUri, required this.rootTitle});

  /// 根地址(smb://host/share、ftp://…、file:///…)
  final String rootUri;
  final String rootTitle;

  @override
  State<VlcBrowsePage> createState() => _VlcBrowsePageState();
}

class _Level {
  _Level({required this.title, required this.uri});

  final String title;
  final String uri;
  final List<VlcBrowseItem> items = [];
}

class _VlcBrowsePageState extends State<VlcBrowsePage> {
  final List<_Level> _stack = [];
  final RxBool _loading = false.obs;
  final RxnString _error = RxnString();
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';
  bool _searching = false;
  int _gen = 0; // 浏览代数: 让在飞的旧会话结果作废

  _Level get _current => _stack.last;

  @override
  void initState() {
    super.initState();
    _push(widget.rootTitle, widget.rootUri);
  }

  @override
  void dispose() {
    VlcBrowser.instance.stop();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _push(String title, String uri) async {
    final level = _Level(title: title, uri: uri);
    setState(() {
      _stack.add(level);
      _exitSearch();
    });
    await _browse(level);
  }

  Future<void> _browse(_Level level) async {
    final gen = ++_gen;
    _loading.value = true;
    _error.value = null;
    await VlcBrowser.instance.browse(
      level.uri,
      showHidden: Pref.localMediaShowHidden,
      onItem: (item) {
        if (gen != _gen || !mounted) {
          return;
        }
        setState(() => level.items.add(item));
      },
      onEnd: () {
        if (gen != _gen || !mounted) {
          return;
        }
        _loading.value = false;
      },
      onError: (msg) {
        if (gen != _gen || !mounted) {
          return;
        }
        _loading.value = false;
        _error.value = msg;
      },
    );
  }

  void _popLevel() {
    if (_stack.length <= 1) {
      Get.back();
      return;
    }
    _gen++;
    setState(() {
      _stack.removeLast();
      _exitSearch();
    });
  }

  void _handleBack() {
    if (_searching) {
      setState(_exitSearch);
      return;
    }
    if (_stack.length > 1) {
      _popLevel();
      return;
    }
    Get.back();
  }

  List<VlcBrowseItem> get _effectiveItems {
    final items = _current.items;
    if (_query.isEmpty) {
      return items;
    }
    final q = _query.toLowerCase();
    return [for (final e in items) if (e.name.toLowerCase().contains(q)) e];
  }

  void _play(VlcBrowseItem item) {
    final siblings = [
      for (final e in _current.items) if (e.isPlayable) e,
    ];
    final playlist = [
      for (final s in siblings)
        VlcPlaylistEntry(uri: s.uri, title: s.name),
    ];
    final index = playlist.indexWhere((e) => e.uri == item.uri);
    Get.to(
      () => VlcPlayerPage(playlist: playlist, initialIndex: index < 0 ? 0 : index),
    );
  }

  void _enterSearch() => setState(() {
    _searching = true;
    _query = '';
  });

  void _exitSearch() {
    _searching = false;
    _query = '';
    _searchCtrl.clear();
  }

  BuildContext? _dlDialogContext;
  StateSetter? _dlSetState;
  double _dlProgress = 0;
  bool _dlCancelled = false;
  bool _dlBusy = false;

  /// 下载到本机(libvlc Dumper, 与播放同一条 SMB/FTP 通道)。
  Future<void> _download(VlcBrowseItem item) async {
    if (_dlBusy) {
      return;
    }
    _dlBusy = true;
    _dlCancelled = false;
    _dlProgress = 0;
    final dest = path.join(downloadPath, item.name);
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) {
          _dlDialogContext = dialogContext;
          return StatefulBuilder(
            builder: (dialogContext, setDialogState) {
              _dlSetState = setDialogState;
              return AlertDialog(
                title: Text(
                  '下载 ${item.name}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 15),
                ),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 10,
                  children: [
                    LinearProgressIndicator(value: _dlProgress),
                    Text(
                      '${(_dlProgress * 100).toStringAsFixed(0)}%',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ],
                ),
                actions: [
                  TextButton(
                    onPressed: () {
                      _dlCancelled = true;
                      VlcBrowser.instance.cancelDump();
                      Navigator.of(dialogContext).pop();
                    },
                    child: const Text('取消'),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
    await VlcBrowser.instance.dump(
      item.uri,
      dest,
      onProgress: (p) {
        _dlProgress = p.clamp(0.0, 1.0);
        _dlSetState?.call(() {});
      },
      onFinished: (ok) {
        _closeDownloadDialog();
        if (ok) {
          SmartDialog.showToast(
            '已保存到 $dest',
            displayTime: const Duration(seconds: 4),
          );
        } else {
          SmartDialog.showToast(_dlCancelled ? '已取消下载' : '下载失败');
        }
        _dlBusy = false;
      },
    );
  }

  void _closeDownloadDialog() {
    final dialogContext = _dlDialogContext;
    _dlDialogContext = null;
    _dlSetState = null;
    if (dialogContext != null && dialogContext.mounted) {
      Navigator.of(dialogContext).pop();
    }
  }

  void _showItemMenu(VlcBrowseItem item) {
    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (item.isPlayable)
              ListTile(
                leading: const Icon(Icons.play_arrow),
                title: const Text('播放'),
                onTap: () {
                  Get.back();
                  _play(item);
                },
              ),
            if (item.isPlayable)
              ListTile(
                leading: const Icon(Icons.download_outlined),
                title: const Text('下载到本机'),
                onTap: () {
                  Get.back();
                  _download(item);
                },
              ),
            ListTile(
              leading: const Icon(Icons.link),
              title: const Text('复制地址(隐藏密码)'),
              onTap: () {
                Get.back();
                Clipboard.setData(
                  ClipboardData(text: VlcSavedShare(name: '', uri: item.uri).maskedUri),
                );
                SmartDialog.showToast('已复制');
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) {
          return;
        }
        _handleBack();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_searching ? '检索当前目录' : _current.title),
          actions: [
            if (!_searching) ...[
              IconButton(
                tooltip: '检索',
                icon: const Icon(Icons.search),
                onPressed: _enterSearch,
              ),
              IconButton(
                tooltip: '刷新',
                icon: const Icon(Icons.refresh),
                onPressed: () => _browse(_current),
              ),
            ] else
              IconButton(
                tooltip: '退出检索',
                icon: const Icon(Icons.close),
                onPressed: () => setState(_exitSearch),
              ),
          ],
          bottom: _searching
              ? PreferredSize(
                  preferredSize: const Size.fromHeight(52),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                    child: TextField(
                      controller: _searchCtrl,
                      autofocus: true,
                      decoration: const InputDecoration(
                        hintText: '过滤当前目录…',
                        prefixIcon: Icon(Icons.search),
                        isDense: true,
                      ),
                      onChanged: (v) => setState(() => _query = v),
                    ),
                  ),
                )
              : null,
        ),
        body: Column(
          children: [
            if (_stack.length > 1)
              ListTile(
                dense: true,
                leading: const Icon(Icons.drive_file_move_outlined),
                title: const Text('..'),
                onTap: _popLevel,
              ),
            Expanded(
              child: Obx(() {
                if (_error.value case final err?) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        err,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  );
                }
                final items = _effectiveItems;
                if (items.isEmpty && _loading.value) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (items.isEmpty) {
                  return const Center(
                    child: Text('空目录', style: TextStyle(fontSize: 13)),
                  );
                }
                return ListView.builder(
                  itemCount: items.length + (_loading.value ? 1 : 0),
                  itemBuilder: (context, i) {
                    if (i >= items.length) {
                      return const ListTile(
                        dense: true,
                        leading: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        title: Text('加载中…', style: TextStyle(fontSize: 13)),
                      );
                    }
                    final item = items[i];
                    return ListTile(
                      leading: Icon(
                        item.isDir
                            ? Icons.folder_outlined
                            : Icons.movie_outlined,
                      ),
                      title: Text(
                        item.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: item.durationMs > 0
                          ? Text(
                              DurationUtils.formatDuration(
                                item.durationMs ~/ 1000,
                              ),
                              style: const TextStyle(fontSize: 12),
                            )
                          : null,
                      trailing: item.isDir
                          ? const Icon(Icons.chevron_right)
                          : null,
                      onTap: () {
                        if (item.isDir) {
                          _push(item.name, item.uri);
                        } else {
                          _play(item);
                        }
                      },
                      onLongPress: () => _showItemMenu(item),
                    );
                  },
                );
              }),
            ),
          ],
        ),
      ),
    );
  }
}
