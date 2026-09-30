import 'package:PiliPlus/common/widgets/flutter/pop_scope.dart';
import 'package:PiliPlus/common/widgets/loading_widget/http_error.dart';
import 'package:PiliPlus/common/widgets/loading_widget/loading_widget.dart';
import 'package:PiliPlus/common/widgets/scaffold/simple_scaffold.dart';
import 'package:PiliPlus/common/widgets/view_sliver_safe_area.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models/common/video/source_type.dart';
import 'package:PiliPlus/models/local_media/local_media_item.dart';
import 'package:PiliPlus/models/local_media/local_media_sort.dart';
import 'package:PiliPlus/models/local_media/local_media_source.dart';
import 'package:PiliPlus/services/local_media_service.dart';
import 'package:PiliPlus/utils/cache_manager.dart';
import 'package:PiliPlus/utils/duration_utils.dart';
import 'package:PiliPlus/utils/local_media_progress.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:material_ui/material_ui.dart';

/// 目录浏览页: 从一个来源(本机目录 / SMB 共享 / WebDAV)的某个路径开始逐层浏览。
///
/// 点一个视频就播放, 同目录的其他视频自动成为播放列表; 返回键逐层回退。
class LocalMediaBrowserPage extends StatefulWidget {
  const LocalMediaBrowserPage({
    super.key,
    required this.source,
    required this.path,
    this.title,
    this.initialItems,
  });

  final LocalMediaSource source;
  final String path;
  final String? title;

  /// 已经取到的条目(例如从媒体库点进文件夹时), 可以避免再列一次目录
  final List<LocalMediaItem>? initialItems;

  @override
  State<LocalMediaBrowserPage> createState() => _LocalMediaBrowserPageState();
}

class _LocalMediaBrowserPageState extends State<LocalMediaBrowserPage> {
  final List<_Level> _stack = [];
  LoadingState<List<LocalMediaItem>> _state = LoadingState.loading();
  LocalMediaSort _sort = Pref.localMediaSort;
  bool _showHidden = Pref.localMediaShowHidden;
  Map<String, Duration> _progress = const {};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _stack.add(
      _Level(
        source: widget.source,
        path: widget.path,
        title: widget.title ?? widget.source.name,
      ),
    );
    final initial = widget.initialItems;
    if (initial != null && initial.isNotEmpty) {
      _state = Success(initial);
      _syncProgress(initial);
    } else {
      _refresh();
    }
  }

  List<LocalMediaItem> get _items => _state.dataOrNull ?? const [];

  _Level get _current => _stack.last;

  Future<void> _refresh() async {
    setState(() => _state = LoadingState.loading());
    final level = _current;
    final res = await LocalMediaService.list(
      source: level.source,
      path: level.path,
      sort: _sort,
      showHidden: _showHidden,
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _state = res;
      _syncProgress(res.dataOrNull ?? const []);
    });
  }

  void _syncProgress(List<LocalMediaItem> items) {
    final next = <String, Duration>{};
    for (final item in items) {
      if (LocalMediaProgress.get(item.uri) case final p?) {
        next[item.uri] = p;
      }
    }
    _progress = next;
  }

  Future<void> _open(LocalMediaItem item) async {
    if (!item.isDirectory) {
      await _play(item);
      return;
    }
    final childPath = _current.source.type == LocalMediaSourceType.device
        ? item.uri
        : item.remotePath ?? item.uri;
    setState(() {
      _stack.add(
        _Level(source: _current.source, path: childPath, title: item.name),
      );
    });
    await _refresh();
  }

  bool _back() {
    if (_stack.length <= 1) {
      return false;
    }
    setState(() => _stack.removeLast());
    _refresh();
    return true;
  }

  Future<void> _play(LocalMediaItem item) async {
    if (_busy) {
      return;
    }
    _busy = true;
    try {
      // SMB 需要先在本机代理上注册一个回环地址(打包的 FFmpeg 没有 smb 协议)
      final url = await LocalMediaService.resolvePlayUrl(item);
      final siblings = _items.where((e) => e.isVideo).toList();
      final index = siblings.indexWhere((e) => e.uri == item.uri);
      final list = index >= 0 ? siblings : <LocalMediaItem>[item];
      if (!mounted) {
        return;
      }
      await PageUtils.toVideoPage(
        aid: 0,
        bvid: '',
        cid: item.cid,
        title: item.name,
        extraArguments: {
          'sourceType': SourceType.localMedia,
          'localMedia': item,
          'localPlaylist': list,
          'localIndex': index >= 0 ? index : 0,
          'localPlayUrl': url,
        },
      );
      // 播放页返回后刷新续播进度
      if (mounted) {
        setState(() => _syncProgress(_items));
      }
    } on Object catch (err) {
      SmartDialog.showToast('无法播放: $err');
    } finally {
      _busy = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return popScope(
      canPop: _stack.length <= 1,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          _back();
        }
      },
      child: SimpleScaffold(
        appBar: AppBar(
          title: Text(
            _current.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            PopupMenuButton<LocalMediaSort>(
              tooltip: '排序',
              initialValue: _sort,
              icon: const Icon(Icons.sort),
              onSelected: (value) {
                setState(() => _sort = value);
                final current = _state.dataOrNull;
                if (current != null) {
                  setState(
                    () => _state = Success(
                      LocalMediaService.sortItems(current, value),
                    ),
                  );
                }
              },
              itemBuilder: (context) => LocalMediaSort.values
                  .map((e) => PopupMenuItem(value: e, child: Text(e.label)))
                  .toList(),
            ),
            IconButton(
              tooltip: _showHidden ? '隐藏隐藏文件' : '显示隐藏文件',
              onPressed: () {
                setState(() => _showHidden = !_showHidden);
                _refresh();
              },
              icon: Icon(
                _showHidden
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
              ),
            ),
            IconButton(
              tooltip: '刷新',
              onPressed: _busy ? null : _refresh,
              icon: const Icon(Icons.refresh),
            ),
            const SizedBox(width: 6),
          ],
        ),
        body: CustomScrollView(
          slivers: [
            ViewSliverSafeArea(
              sliver: switch (_state) {
                Loading() => linearLoading,
                Error(:final errMsg) => HttpError(
                  errMsg: errMsg,
                  onReload: _refresh,
                ),
                Success() => _buildList(),
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildList() {
    final items = _items;
    if (items.isEmpty) {
      return HttpError(errMsg: '这里没有可播放的媒体文件', onReload: _refresh);
    }
    return SliverList.builder(
      itemCount: items.length + (_stack.length > 1 ? 1 : 0),
      itemBuilder: (context, index) {
        if (_stack.length > 1 && index == 0) {
          return ListTile(
            leading: const Icon(Icons.drive_file_move_rtl_outlined),
            title: const Text('..'),
            subtitle: Text(_stack[_stack.length - 2].title),
            onTap: _back,
          );
        }
        final item = items[index - (_stack.length > 1 ? 1 : 0)];
        return _buildItem(item);
      },
    );
  }

  Widget _buildItem(LocalMediaItem item) {
    final progress = _progress[item.uri];
    final subtitle = <String>[
      if (item.size case final size?) CacheManager.formatSize(size),
      if (item.modified case final modified?) _formatDate(modified),
      if (progress case final p?)
        '看到 ${DurationUtils.formatDuration(p.inSeconds)}',
    ].join(' · ');
    return ListTile(
      leading: Icon(
        item.isDirectory
            ? Icons.folder_outlined
            : item.isAudio
            ? Icons.audiotrack_outlined
            : Icons.movie_outlined,
      ),
      title: Text(item.name, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: subtitle.isEmpty
          ? null
          : Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: item.isDirectory
          ? const Icon(Icons.chevron_right)
          : progress == null
          ? null
          : const Icon(Icons.history_outlined, size: 18),
      onTap: () => _open(item),
      onLongPress: () => _showItemMenu(item),
    );
  }

  void _showItemMenu(LocalMediaItem item) {
    final masked = LocalMediaService.maskedUrl(item.uri);
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(item.name, maxLines: 2, overflow: TextOverflow.ellipsis),
        contentPadding: const EdgeInsets.symmetric(vertical: 8),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              dense: true,
              leading: const Icon(Icons.info_outline),
              title: const Text('详情'),
              subtitle: Text(
                [
                  '来源: ${item.source.name}',
                  if (item.size case final size?)
                    '大小: ${CacheManager.formatSize(size)}',
                  if (item.modified case final modified?)
                    '修改: ${_formatDate(modified)}',
                  '路径: $masked',
                ].join('\n'),
                style: const TextStyle(fontSize: 12),
              ),
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.link),
              title: const Text('复制地址(不含密码)'),
              onTap: () {
                Navigator.of(dialogContext).pop();
                Clipboard.setData(ClipboardData(text: masked));
                SmartDialog.showToast('已复制');
              },
            ),
            if (_progress.containsKey(item.uri))
              ListTile(
                dense: true,
                leading: const Icon(Icons.delete_sweep_outlined),
                title: const Text('清除播放进度'),
                onTap: () {
                  Navigator.of(dialogContext).pop();
                  LocalMediaProgress.clear(item.uri);
                  setState(() => _syncProgress(_items));
                  SmartDialog.showToast('已清除');
                },
              ),
          ],
        ),
      ),
    );
  }

  static String _formatDate(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}';
  }
}

class _Level {
  const _Level({
    required this.source,
    required this.path,
    required this.title,
  });

  final LocalMediaSource source;
  final String path;
  final String title;
}
